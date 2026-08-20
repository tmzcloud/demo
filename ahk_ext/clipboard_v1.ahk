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
cGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiAycHg7IGZsZXgtd3JhcDogbm93cmFw
OwogICAgICAgICAgICBwYWRkaW5nOiA1cHggNnB4IDVweCA4cHg7IGZsZXgtc2hyaW5rOiAwOwogICAg
ICAgICAgICBiYWNrZ3JvdW5kOiAjZjJmNGY5OwogICAgICAgIH0KICAgICAgICAjdGFiLWluayB7CiAg
ICAgICAgICAgIHBvc2l0aW9uOiBhYnNvbHV0ZTsKICAgICAgICAgICAgbGVmdDogMDsgdG9wOiAwOwog
ICAgICAgICAgICBoZWlnaHQ6IDIycHg7CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6IDk5OXB4Owog
ICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZmZmOwogICAgICAgICAgICBib3gtc2hhZG93OiAwIDFweCAz
cHggcmdiYSgwLDAsMCwuMDcpLCAwIDAgMCAxcHggcmdiYSg5MSwxMTUsMjMyLC4wNik7CiAgICAgICAg
ICAgIHBvaW50ZXItZXZlbnRzOiBub25lOwogICAgICAgICAgICB6LWluZGV4OiAwOwogICAgICAgICAg
ICB0cmFuc2Zvcm06IHRyYW5zbGF0ZTNkKDAsMCwwKSBzY2FsZVgoMSk7CiAgICAgICAgICAgIHRyYW5z
Zm9ybS1vcmlnaW46IGNlbnRlciBib3R0b207CiAgICAgICAgICAgIHRyYW5zaXRpb246CiAgICAgICAg
ICAgICAgICB0cmFuc2Zvcm0gMC4zNHMgY3ViaWMtYmV6aWVyKDAuMjIsIDEuMTgsIDAuMzIsIDEpLAog
ICAgICAgICAgICAgICAgaGVpZ2h0IDAuMjRzIGVhc2U7CiAgICAgICAgICAgIHdpbGwtY2hhbmdlOiB0
cmFuc2Zvcm0sIGhlaWdodDsKICAgICAgICB9CiAgICAgICAgI3RhYi1pbmsuc3F1YXNoIHsKICAgICAg
ICAgICAgdHJhbnNpdGlvbjoKICAgICAgICAgICAgICAgIHRyYW5zZm9ybSAwLjMwcyBjdWJpYy1iZXpp
ZXIoMC4zNCwgMS4yOCwgMC40NCwgMSksCiAgICAgICAgICAgICAgICBoZWlnaHQgMC4yMHMgZWFzZTsK
ICAgICAgICB9CiAgICAgICAgLnRhYiB7CiAgICAgICAgICAgIHBvc2l0aW9uOiByZWxhdGl2ZTsKICAg
ICAgICAgICAgei1pbmRleDogMTsKICAgICAgICAgICAgcGFkZGluZzogM3B4IDEwcHg7IGZvbnQtc2l6
ZTogMTFweDsgY29sb3I6IHZhcigtLXR4dDIpOyBjdXJzb3I6IHBvaW50ZXI7CiAgICAgICAgICAgIGJv
cmRlci1yYWRpdXM6IDk5OXB4OyB3aGl0ZS1zcGFjZTogbm93cmFwOwogICAgICAgICAgICBiYWNrZ3Jv
dW5kOiB0cmFuc3BhcmVudDsKICAgICAgICAgICAgdHJhbnNpdGlvbjogY29sb3IgMC4yOHMgY3ViaWMt
YmV6aWVyKDAuMjIsIDEsIDAuMzYsIDEpLAogICAgICAgICAgICAgICAgICAgICAgICB0cmFuc2Zvcm0g
MC4yOHMgY3ViaWMtYmV6aWVyKDAuMjIsIDEsIDAuMzYsIDEpOwogICAgICAgICAgICAtd2Via2l0LWFw
cC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgfQogICAgICAgIC50
YWI6aG92ZXIgeyBjb2xvcjogdmFyKC0tdHh0KTsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7IH0KICAg
ICAgICAudGFiOmFjdGl2ZSB7IHRyYW5zZm9ybTogc2NhbGUoMC45Nik7IH0KICAgICAgICAudGFiLm9u
IHsgY29sb3I6IHZhcigtLWFjYyk7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OyBib3gtc2hhZG93OiBu
b25lOyBmb250LXdlaWdodDogNjAwOyB9CiAgICAgICAgLmJhZGdlIHsKICAgICAgICAgICAgZGlzcGxh
eTogaW5saW5lLWZsZXg7IG1pbi13aWR0aDogMTRweDsgaGVpZ2h0OiAxNHB4OyBwYWRkaW5nOiAwIDNw
eDsKICAgICAgICAgICAgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7
CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHZhcigtLWFjYyk7IGNvbG9yOiAjZmZmOyBmb250LXNpemU6
IDlweDsgYm9yZGVyLXJhZGl1czogN3B4OyBmb250LXdlaWdodDogNzAwOwogICAgICAgIH0KICAgICAg
ICAjdGFiLWFjdGlvbnMgewogICAgICAgICAgICBtYXJnaW4tbGVmdDogYXV0bzsgZGlzcGxheTogZmxl
eDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA0cHg7CiAgICAgICAgICAgIGNvbG9yOiB2YXIoLS10
eHQzKTsgZm9udC1zaXplOiAxMHB4OwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRy
YWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgfQogICAgICAgICNiYXItdHh0IHsgd2hpdGUt
c3BhY2U6IG5vd3JhcDsgfQogICAgICAgICNidG4tY2xyIHsKICAgICAgICAgICAgZGlzcGxheTogZmxl
eDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7CiAgICAgICAgICAg
IHdpZHRoOiAyNnB4OyBoZWlnaHQ6IDI2cHg7IGJvcmRlcjogbm9uZTsgYmFja2dyb3VuZDogbm9uZTsg
Y29sb3I6IHZhcigtLXR4dDMpOwogICAgICAgICAgICBjdXJzb3I6IHBvaW50ZXI7IGJvcmRlci1yYWRp
dXM6IHZhcigtLXIpOwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1y
ZWdpb246IG5vLWRyYWc7CiAgICAgICAgICAgIHRyYW5zaXRpb246IGNvbG9yIHZhcigtLXRyKSwgYmFj
a2dyb3VuZCB2YXIoLS10cik7CiAgICAgICAgfQogICAgICAgICNidG4tY2xyOmhvdmVyIHsgY29sb3I6
ICNmZjdiOWM7IGJhY2tncm91bmQ6IHJnYmEoMjU1LDEyMywxNTYsLjA4KTsgfQogICAgICAgICNidG4t
Y2xyIHN2ZyB7IHdpZHRoOiAxNHB4OyBoZWlnaHQ6IDE0cHg7IGRpc3BsYXk6IGJsb2NrOyB9CgogICAg
ICAgIC8qIOKUgOKUgCBMaXN0IOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgCAqLwogICAgICAgICNsaXN0IHsKICAgICAgICAgICAgZmxleDogMTsg
b3ZlcmZsb3cteTogYXV0bzsgb3ZlcmZsb3cteDogaGlkZGVuOyBwYWRkaW5nOiA2cHggOHB4IDZweCAx
MHB4OyBjdXJzb3I6IGRlZmF1bHQ7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogZHJhZzsg
YXBwLXJlZ2lvbjogZHJhZzsKICAgICAgICAgICAgbWluLWhlaWdodDogMDsKICAgICAgICB9CiAgICAg
ICAgQGtleWZyYW1lcyB0YWJQYW5lSW5MciB7CiAgICAgICAgICAgIGZyb20geyBvcGFjaXR5OiAwOyB0
cmFuc2Zvcm06IHRyYW5zbGF0ZVgoLTQwcHgpOyB9CiAgICAgICAgICAgIHRvIHsgb3BhY2l0eTogMTsg
dHJhbnNmb3JtOiB0cmFuc2xhdGVYKDApOyB9CiAgICAgICAgfQogICAgICAgIEBrZXlmcmFtZXMgdGFi
UGFuZUluUmwgewogICAgICAgICAgICBmcm9tIHsgb3BhY2l0eTogMDsgdHJhbnNmb3JtOiB0cmFuc2xh
dGVYKDQwcHgpOyB9CiAgICAgICAgICAgIHRvIHsgb3BhY2l0eTogMTsgdHJhbnNmb3JtOiB0cmFuc2xh
dGVYKDApOyB9CiAgICAgICAgfQogICAgICAgICNsaXN0LnRhYi1pbi1sciB7IGFuaW1hdGlvbjogdGFi
UGFuZUluTHIgLjM0cyBjdWJpYy1iZXppZXIoLjIyLCAxLCAuMzYsIDEpIGJvdGg7IH0KICAgICAgICAj
bGlzdC50YWItaW4tcmwgeyBhbmltYXRpb246IHRhYlBhbmVJblJsIC4zNHMgY3ViaWMtYmV6aWVyKC4y
MiwgMSwgLjM2LCAxKSBib3RoOyB9CiAgICAgICAgI2J0bi10b3AgewogICAgICAgICAgICBwb3NpdGlv
bjogYWJzb2x1dGU7IHJpZ2h0OiAxMHB4OyBib3R0b206IDEwcHg7IHotaW5kZXg6IDIwOwogICAgICAg
ICAgICB3aWR0aDogMjhweDsgaGVpZ2h0OiAyOHB4OyBib3JkZXI6IG5vbmU7IGJvcmRlci1yYWRpdXM6
IDUwJTsKICAgICAgICAgICAgZGlzcGxheTogbm9uZTsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlm
eS1jb250ZW50OiBjZW50ZXI7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNmZmY7IGNvbG9yOiB2YXIo
LS10eHQyKTsKICAgICAgICAgICAgYm94LXNoYWRvdzogMCAycHggOHB4IHJnYmEoMjQsMzIsNTYsLjE2
KTsKICAgICAgICAgICAgY3Vyc29yOiBwb2ludGVyOwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdp
b246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgICAgIHRyYW5zaXRpb246IGJh
Y2tncm91bmQgdmFyKC0tdHIpLCBjb2xvciB2YXIoLS10ciksIGJveC1zaGFkb3cgdmFyKC0tdHIpOwog
ICAgICAgIH0KICAgICAgICAjYnRuLXRvcC5vbiB7IGRpc3BsYXk6IGZsZXg7IH0KICAgICAgICAjYnRu
LXRvcDpob3ZlciB7IGNvbG9yOiB2YXIoLS1hY2MpOyBiYWNrZ3JvdW5kOiAjZWRmMWZmOyBib3gtc2hh
ZG93OiAwIDNweCAxMHB4IHJnYmEoOTEsMTE1LDIzMiwuMjUpOyB9CiAgICAgICAgI2J0bi10b3Agc3Zn
IHsgd2lkdGg6IDE0cHg7IGhlaWdodDogMTRweDsgZGlzcGxheTogYmxvY2s7IH0KICAgICAgICAjZW1w
dHkgewogICAgICAgICAgICBkaXNwbGF5OiBub25lOyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBhbGln
bi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAgICAgICAgICAgcGFkZGlu
ZzogNDhweCAxNnB4OyBjb2xvcjogdmFyKC0tdHh0Myk7IGdhcDogOHB4OwogICAgICAgICAgICAtd2Vi
a2l0LWFwcC1yZWdpb246IGRyYWc7IGFwcC1yZWdpb246IGRyYWc7CiAgICAgICAgfQogICAgICAgICNl
bXB0eS5vbiB7IGRpc3BsYXk6IGZsZXg7IH0KICAgICAgICAuZS10eHQgeyBmb250LXNpemU6IDEycHg7
IHRleHQtYWxpZ246IGNlbnRlcjsgbGV0dGVyLXNwYWNpbmc6IC4wMmVtOyB9CiAgICAgICAgI3NrZWwg
ewogICAgICAgICAgICBkaXNwbGF5OiBub25lOyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBnYXA6IDhw
eDsKICAgICAgICAgICAgcGFkZGluZzogNHB4IDJweCAxMHB4OyAtd2Via2l0LWFwcC1yZWdpb246IGRy
YWc7IGFwcC1yZWdpb246IGRyYWc7CiAgICAgICAgfQogICAgICAgICNza2VsLm9uIHsgZGlzcGxheTog
ZmxleDsgfQogICAgICAgICNhcHAuYm9vdC1sb2FkaW5nICNza2VsIHsKICAgICAgICAgICAgZGlzcGxh
eTogZmxleCAhaW1wb3J0YW50OwogICAgICAgIH0KICAgICAgICAjYXBwLmJvb3QtbG9hZGluZyAjZW1w
dHkgewogICAgICAgICAgICBkaXNwbGF5OiBub25lICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAg
IC5zay1yb3cgewogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogZmxleC1zdGFy
dDsgZ2FwOiAxMHB4OwogICAgICAgICAgICBwYWRkaW5nOiAxMHB4IDhweDsgYm9yZGVyLXJhZGl1czog
OHB4OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDI1NSwyNTUsMjU1LC43Mik7CiAgICAgICAg
ICAgIGJvcmRlcjogMXB4IHNvbGlkIHJnYmEoMTcwLDE4MCwyMDAsLjQ1KTsKICAgICAgICAgICAgcG9z
aXRpb246IHJlbGF0aXZlOwogICAgICAgICAgICBvdmVyZmxvdzogaGlkZGVuOwogICAgICAgIH0KICAg
ICAgICAuc2stcm93OjphZnRlciB7CiAgICAgICAgICAgIGNvbnRlbnQ6ICcnOwogICAgICAgICAgICBw
b3NpdGlvbjogYWJzb2x1dGU7CiAgICAgICAgICAgIGluc2V0OiAwOwogICAgICAgICAgICBiYWNrZ3Jv
dW5kOiBsaW5lYXItZ3JhZGllbnQoOTBkZWcsIHRyYW5zcGFyZW50IDAlLCByZ2JhKDI1NSwyNTUsMjU1
LC43MikgNDglLCB0cmFuc3BhcmVudCAxMDAlKTsKICAgICAgICAgICAgdHJhbnNmb3JtOiB0cmFuc2xh
dGVYKC0xMjAlKTsKICAgICAgICAgICAgYW5pbWF0aW9uOiBzay1zd2VlcCAwLjk1cyBlYXNlLWluLW91
dCBpbmZpbml0ZTsKICAgICAgICAgICAgcG9pbnRlci1ldmVudHM6IG5vbmU7CiAgICAgICAgfQogICAg
ICAgIEBrZXlmcmFtZXMgc2stc3dlZXAgewogICAgICAgICAgICAxMDAlIHsgdHJhbnNmb3JtOiB0cmFu
c2xhdGVYKDEyMCUpOyB9CiAgICAgICAgfQogICAgICAgIC5zay1pY28sIC5zay1saW5lIHsKICAgICAg
ICAgICAgYmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50KDkwZGVnLCAjYjhjMmQ4IDAlLCAjZjBmNGZh
IDM4JSwgI2RjZTNmMCA1MiUsICNiOGMyZDggMTAwJSk7CiAgICAgICAgICAgIGJhY2tncm91bmQtc2l6
ZTogMjQwJSAxMDAlOwogICAgICAgICAgICBhbmltYXRpb246IHNrLXNoaW1tZXIgMC43MnMgZWFzZS1p
bi1vdXQgaW5maW5pdGU7CiAgICAgICAgICAgIHdpbGwtY2hhbmdlOiBiYWNrZ3JvdW5kLXBvc2l0aW9u
OwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiA2cHg7CiAgICAgICAgfQogICAgICAgIC5zay1pY28g
eyB3aWR0aDogMzRweDsgaGVpZ2h0OiAzNHB4OyBmbGV4LXNocmluazogMDsgYm9yZGVyLXJhZGl1czog
OHB4OyB9CiAgICAgICAgLnNrLWJvZHkgeyBmbGV4OiAxOyBtaW4td2lkdGg6IDA7IGRpc3BsYXk6IGZs
ZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGdhcDogOHB4OyBwYWRkaW5nLXRvcDogMnB4OyB9CiAg
ICAgICAgLnNrLWxpbmUgeyBoZWlnaHQ6IDEwcHg7IHdpZHRoOiAxMDAlOyB9CiAgICAgICAgLnNrLWxp
bmUuc2hvcnQgeyB3aWR0aDogNDIlOyB9CiAgICAgICAgLnNrLWxpbmUubWlkIHsgd2lkdGg6IDY4JTsg
fQogICAgICAgIC5zay1yb3c6bnRoLWNoaWxkKDIpOjphZnRlciB7IGFuaW1hdGlvbi1kZWxheTogLjEy
czsgfQogICAgICAgIC5zay1yb3c6bnRoLWNoaWxkKDMpOjphZnRlciB7IGFuaW1hdGlvbi1kZWxheTog
LjI0czsgfQogICAgICAgIC5zay1yb3c6bnRoLWNoaWxkKDQpOjphZnRlciB7IGFuaW1hdGlvbi1kZWxh
eTogLjM2czsgfQogICAgICAgIC5zay1yb3c6bnRoLWNoaWxkKDUpOjphZnRlciB7IGFuaW1hdGlvbi1k
ZWxheTogLjQ4czsgfQogICAgICAgIC5zay1yb3c6bnRoLWNoaWxkKDYpOjphZnRlciB7IGFuaW1hdGlv
bi1kZWxheTogLjZzOyB9CiAgICAgICAgQGtleWZyYW1lcyBzay1zaGltbWVyIHsKICAgICAgICAgICAg
MCUgeyBiYWNrZ3JvdW5kLXBvc2l0aW9uOiAxMDAlIDA7IH0KICAgICAgICAgICAgMTAwJSB7IGJhY2tn
cm91bmQtcG9zaXRpb246IC0xMDAlIDA7IH0KICAgICAgICB9CiAgICAgICAgLmxpc3QtbW9yZSB7CiAg
ICAgICAgICAgIHRleHQtYWxpZ246IGNlbnRlcjsgcGFkZGluZzogMTBweCA4cHggMTRweDsgZm9udC1z
aXplOiAxMXB4OwogICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0Myk7IC13ZWJraXQtYXBwLXJlZ2lv
bjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICB9CiAgICAgICAgLmxpc3QtbW9y
ZS5kb25lIHsgZGlzcGxheTogbm9uZTsgfQoKICAgICAgICAuaXRtIHsKICAgICAgICAgICAgZGlzcGxh
eTogZmxleDsgYWxpZ24taXRlbXM6IGZsZXgtc3RhcnQ7IGdhcDogOHB4OwogICAgICAgICAgICBwYWRk
aW5nOiA4cHg7IG1hcmdpbi1ib3R0b206IDVweDsKICAgICAgICAgICAgYmFja2dyb3VuZDogdmFyKC0t
Y2FyZCk7IGJvcmRlci1yYWRpdXM6IHZhcigtLXIpOyBjdXJzb3I6IHBvaW50ZXI7CiAgICAgICAgICAg
IGJveC1zaGFkb3c6IDAgMXB4IDNweCByZ2JhKDI0LDMyLDU2LC4wNik7CiAgICAgICAgICAgIC8qIGhv
dmVyLWxpbmUgKi8KICAgICAgICAgICAgcG9zaXRpb246IHJlbGF0aXZlOwogICAgICAgICAgICB0cmFu
c2l0aW9uOiBiYWNrZ3JvdW5kIC4ycyBlYXNlLCBib3gtc2hhZG93IC4ycyBlYXNlOwogICAgICAgICAg
ICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAg
ICAgIG92ZXJmbG93OiB2aXNpYmxlOwogICAgICAgIH0KICAgICAgICAuaXRtOjpiZWZvcmUgewogICAg
ICAgICAgICBjb250ZW50OiAiIjsKICAgICAgICAgICAgcG9zaXRpb246IGFic29sdXRlOwogICAgICAg
ICAgICBsZWZ0OiAwOyByaWdodDogMDsgYm90dG9tOiAwOwogICAgICAgICAgICBoZWlnaHQ6IDA7CiAg
ICAgICAgICAgIHBvaW50ZXItZXZlbnRzOiBub25lOwogICAgICAgICAgICB6LWluZGV4OiAwOwogICAg
ICAgICAgICBib3JkZXItcmFkaXVzOiAwIDAgdmFyKC0tcikgdmFyKC0tcik7CiAgICAgICAgICAgIGJh
Y2tncm91bmQ6IGxpbmVhci1ncmFkaWVudCh0byB0b3AsIHJnYmEoOTEsMTE1LDIzMiwuMzIpLCByZ2Jh
KDkxLDExNSwyMzIsLjEyKSA1NSUsIHRyYW5zcGFyZW50KTsKICAgICAgICAgICAgdHJhbnNpdGlvbjog
aGVpZ2h0IC4zNHMgY3ViaWMtYmV6aWVyKC4yMiwxLC4zNiwxKTsKICAgICAgICB9CiAgICAgICAgLml0
bTpob3Zlcjo6YmVmb3JlIHsgaGVpZ2h0OiAzMy4zMzMlOyB9CiAgICAgICAgLml0bTo6YWZ0ZXIgewog
ICAgICAgICAgICBjb250ZW50OiAiIjsKICAgICAgICAgICAgcG9zaXRpb246IGFic29sdXRlOwogICAg
ICAgICAgICBsZWZ0OiAwOyByaWdodDogMDsgYm90dG9tOiAwOwogICAgICAgICAgICBoZWlnaHQ6IDJw
eDsKICAgICAgICAgICAgcG9pbnRlci1ldmVudHM6IG5vbmU7CiAgICAgICAgICAgIHotaW5kZXg6IDE7
CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoOTEsMTE1LDIzMiwuOTUpOwogICAgICAgICAgICBi
b3JkZXItcmFkaXVzOiAxcHg7CiAgICAgICAgICAgIHRyYW5zZm9ybTogc2NhbGVYKDApOwogICAgICAg
ICAgICB0cmFuc2Zvcm0tb3JpZ2luOiBjZW50ZXI7CiAgICAgICAgICAgIHRyYW5zaXRpb246IHRyYW5z
Zm9ybSAuM3MgY3ViaWMtYmV6aWVyKC4yMiwxLC4zNiwxKTsKICAgICAgICB9CiAgICAgICAgLml0bTpo
b3ZlciB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHZhcigtLWNhcmQtaCk7CiAgICAgICAgICAgIGJv
eC1zaGFkb3c6IDAgMnB4IDhweCByZ2JhKDI0LDMyLDU2LC4xKTsKICAgICAgICB9CiAgICAgICAgLml0
bTpob3Zlcjo6YWZ0ZXIgewogICAgICAgICAgICB0cmFuc2Zvcm06IHNjYWxlWCgxKTsKICAgICAgICB9
CiAgICAgICAgLml0bS5zZWwgewogICAgICAgICAgICBib3gtc2hhZG93OiAwIDAgMCAycHggcmdiYSg5
MSwxMTUsMjMyLC40NSksIDAgMnB4IDhweCByZ2JhKDkxLDExNSwyMzIsLjE4KTsKICAgICAgICAgICAg
YmFja2dyb3VuZDogI2VkZjFmZjsKICAgICAgICB9CiAgICAgICAgLml0bS5tdWx0aSB7CiAgICAgICAg
ICAgIGJveC1zaGFkb3c6IDAgMCAwIDEuNXB4IHJnYmEoOTEsMTE1LDIzMiwuNTUpLCAwIDJweCA2cHgg
cmdiYSg5MSwxMTUsMjMyLC4xOCk7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNlZWYyZmY7CiAgICAg
ICAgfQogICAgICAgIC5pdG0ubXVsdGkuc2VsIHsKICAgICAgICAgICAgYm94LXNoYWRvdzogMCAwIDAg
MnB4IHJnYmEoOTEsMTE1LDIzMiwuNyksIDAgMnB4IDhweCByZ2JhKDkxLDExNSwyMzIsLjIyKTsKICAg
ICAgICB9CgogICAgICAgICNtdWx0aS1jbnQgewogICAgICAgICAgICBkaXNwbGF5OiBub25lOyBhbGln
bi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAgICAgICAgICAgaGVpZ2h0
OiAyMnB4OyBwYWRkaW5nOiAwIDhweDsgbWFyZ2luLXJpZ2h0OiA0cHg7CiAgICAgICAgICAgIGJvcmRl
cjogbm9uZTsgYm9yZGVyLXJhZGl1czogMTFweDsgY3Vyc29yOiBwb2ludGVyOwogICAgICAgICAgICBi
YWNrZ3JvdW5kOiB2YXIoLS1hY2MpOyBjb2xvcjogI2ZmZjsgZm9udC1zaXplOiAxMXB4OyBmb250LXdl
aWdodDogNzAwOwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdp
b246IG5vLWRyYWc7CiAgICAgICAgICAgIHRyYW5zaXRpb246IG9wYWNpdHkgdmFyKC0tdHIpLCBiYWNr
Z3JvdW5kIHZhcigtLXRyKTsKICAgICAgICB9CiAgICAgICAgI211bHRpLWNudDpob3ZlciB7IGJhY2tn
cm91bmQ6ICM0YTYyZDQ7IH0KICAgICAgICAjbXVsdGktY250Lm9uIHsgZGlzcGxheTogaW5saW5lLWZs
ZXg7IH0KCiAgICAgICAgLmktaWNvIHsKICAgICAgICAgICAgd2lkdGg6IDI4cHg7IGhlaWdodDogMjhw
eDsgYm9yZGVyLXJhZGl1czogdmFyKC0tcik7IGRpc3BsYXk6IGZsZXg7CiAgICAgICAgICAgIGFsaWdu
LWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOyBmbGV4LXNocmluazogMDsKICAg
ICAgICAgICAgYmFja2dyb3VuZDogI2VkZjJmZjsgY29sb3I6IHZhcigtLWFjYyk7CiAgICAgICAgICAg
IHBvc2l0aW9uOiByZWxhdGl2ZTsgb3ZlcmZsb3c6IHZpc2libGU7CiAgICAgICAgfQogICAgICAgIC5p
LWljbyBzdmcgeyB3aWR0aDogMTZweDsgaGVpZ2h0OiAxNnB4OyBkaXNwbGF5OiBibG9jazsgfQogICAg
ICAgIC5pLWljby5mdC1pbWcgeyBjb2xvcjogIzdhZDdmZjsgfQogICAgICAgIC5pLWljby5mdC12aWQg
eyBjb2xvcjogI2MwODRmYzsgfQogICAgICAgIC5pLWljby5mdC16aXAgeyBjb2xvcjogIzhhYjRmZjsg
fQogICAgICAgIC5pLWljby5mdC1kaXIgeyBjb2xvcjogI2ZmZDU2YTsgfQogICAgICAgIC5pLWljby5m
dC1haGsgeyBjb2xvcjogIzZkZmY5YTsgfQogICAgICAgIC5pLWljby5tZCB7IGNvbG9yOiAjNmI4Y2Zm
OyB9CiAgICAgICAgLmktaWNvLm1kIHN2ZyB7IHdpZHRoOiAyMHB4OyBoZWlnaHQ6IDIwcHg7IH0KICAg
ICAgICAuaS1pY28uZnQtbG5rLCAuaS1pY28uZnQtZG9jIHsgY29sb3I6ICNhOWJkZDA7IH0KICAgICAg
ICAuaS11c2VkIHsKICAgICAgICAgICAgcG9zaXRpb246IGFic29sdXRlOyByaWdodDogMDsgYm90dG9t
OiAwOwogICAgICAgICAgICB3aWR0aDogMTNweDsgaGVpZ2h0OiAxM3B4OyBib3JkZXItcmFkaXVzOiA1
MCU7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICMyMmM1NWU7IGJvcmRlcjogMS41cHggc29saWQgI2Zm
ZjsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1j
b250ZW50OiBjZW50ZXI7CiAgICAgICAgICAgIHBvaW50ZXItZXZlbnRzOiBub25lOyB6LWluZGV4OiAz
OwogICAgICAgICAgICBib3gtc2hhZG93OiAwIDFweCAycHggcmdiYSgwLDAsMCwuMTYpOwogICAgICAg
ICAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZSgzMCUsIDMwJSk7CiAgICAgICAgfQogICAgICAgIC5pLXVz
ZWQgc3ZnIHsgd2lkdGg6IDlweDsgaGVpZ2h0OiA5cHg7IGNvbG9yOiAjZmZmOyBkaXNwbGF5OiBibG9j
azsgfQoKICAgICAgICAuaXRtLmp1bXAtZmxhc2ggewogICAgICAgICAgICBib3gtc2hhZG93OiAwIDAg
MCAycHggcmdiYSg5MSwxMTUsMjMyLC41NSksIDAgMnB4IDEwcHggcmdiYSg5MSwxMTUsMjMyLC4yMik7
CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNlOGVkZmY7CiAgICAgICAgICAgIHRyYW5zaXRpb246IGJh
Y2tncm91bmQgLjM1cyBlYXNlLCBib3gtc2hhZG93IC4zNXMgZWFzZTsKICAgICAgICB9CgogICAgICAg
IC5pLWJvZHkgeyBmbGV4OiAxOyBtaW4td2lkdGg6IDA7IGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0
aW9uOiBjb2x1bW47IH0KICAgICAgICAuaS1wcmV2LCAuaS1uYW1lIHsKICAgICAgICAgICAgZm9udC1z
aXplOiAxM3B4OyBmb250LXdlaWdodDogNTAwOyBjb2xvcjogdmFyKC0tdHh0KTsgd29yZC1icmVhazog
YnJlYWstYWxsOwogICAgICAgICAgICB3aGl0ZS1zcGFjZTogcHJlLXdyYXA7IC8qIOaUr+aMgeWkmuaW
h+S7ti/lpJrooYzmlofmnKzmjaLooYzmmL7npLogKi8KICAgICAgICB9CiAgICAgICAgLmktcHJldiB7
CiAgICAgICAgICAgIGRpc3BsYXk6IC13ZWJraXQtYm94OyAtd2Via2l0LWJveC1vcmllbnQ6IHZlcnRp
Y2FsOyAtd2Via2l0LWxpbmUtY2xhbXA6IDU7IG92ZXJmbG93OiBoaWRkZW47CiAgICAgICAgICAgIHRl
eHQtb3ZlcmZsb3c6IGVsbGlwc2lzOwogICAgICAgIH0KICAgICAgICAuaS1uYW1lIHsKICAgICAgICAg
ICAgZGlzcGxheTogLXdlYmtpdC1ib3g7IC13ZWJraXQtYm94LW9yaWVudDogdmVydGljYWw7IC13ZWJr
aXQtbGluZS1jbGFtcDogMjsgb3ZlcmZsb3c6IGhpZGRlbjsKICAgICAgICB9CiAgICAgICAgLyogRmls
ZSBjbGlwIHdob3NlIHBhdGgocykgbm8gbG9uZ2VyIGV4aXN0IOKAlCBsaWdodCBib2xkIGdyYXkgc3Ry
aWtlICovCiAgICAgICAgLml0bS5nb25lIC5pLW5hbWUgewogICAgICAgICAgICBjb2xvcjogIzlhYTBi
MDsKICAgICAgICAgICAgdGV4dC1kZWNvcmF0aW9uOiBsaW5lLXRocm91Z2g7CiAgICAgICAgICAgIHRl
eHQtZGVjb3JhdGlvbi10aGlja25lc3M6IDJweDsKICAgICAgICAgICAgdGV4dC1kZWNvcmF0aW9uLWNv
bG9yOiByZ2JhKDE1NCwgMTYwLCAxNzYsIC41NSk7CiAgICAgICAgICAgIHRleHQtZGVjb3JhdGlvbi1z
a2lwLWluazogbm9uZTsKICAgICAgICB9CiAgICAgICAgLml0bS5nb25lIC5pLWljbyB7IG9wYWNpdHk6
IC41NTsgfQogICAgICAgIC5pdG0uZ29uZSAuaS10aHVtYi13cmFwIHsgb3BhY2l0eTogLjU1OyB9CiAg
ICAgICAgLmktcHJldi51cmwgeyBjb2xvcjogdmFyKC0tYWNjKTsgfQogICAgICAgIC5pLXRodW1iLXdy
YXAgewogICAgICAgICAgICB3aWR0aDogMTAwJTsgbWluLWhlaWdodDogNDhweDsgbWF4LWhlaWdodDog
MTgwcHg7IG1hcmdpbi1ib3R0b206IDRweDsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgYWxpZ24t
aXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7CiAgICAgICAgICAgIGJhY2tncm91
bmQ6ICNmM2Y1Zjk7IGJvcmRlci1yYWRpdXM6IHZhcigtLXIpOyBvdmVyZmxvdzogaGlkZGVuOwogICAg
ICAgIH0KICAgICAgICAuaS10aHVtYiB7IG1heC13aWR0aDogMTAwJTsgbWF4LWhlaWdodDogMTgwcHg7
IHdpZHRoOiBhdXRvOyBoZWlnaHQ6IGF1dG87IG9iamVjdC1maXQ6IGNvbnRhaW47IGRpc3BsYXk6IGJs
b2NrOyB9CgogICAgICAgIC8qIE1ldGEgYmFyOiB0aW1lIGxlZnQgfCBleHBhbmQgY2VudGVyIHwgdGFn
cyByaWdodCAqLwogICAgICAgIC5pLW1ldGEgewogICAgICAgICAgICBkaXNwbGF5OiBncmlkOwogICAg
ICAgICAgICBncmlkLXRlbXBsYXRlLWNvbHVtbnM6IDFmciBhdXRvIDFmcjsKICAgICAgICAgICAgYWxp
Z24taXRlbXM6IGNlbnRlcjsKICAgICAgICAgICAgZ2FwOiA0cHg7CiAgICAgICAgICAgIG1hcmdpbi10
b3A6IDRweDsKICAgICAgICAgICAgd2lkdGg6IDEwMCU7CiAgICAgICAgfQogICAgICAgIC5pLW1ldGEg
LmktdGltZSB7IGp1c3RpZnktc2VsZjogc3RhcnQ7IH0KICAgICAgICAuaS1tZXRhLWNlbnRlciB7CiAg
ICAgICAgICAgIGp1c3RpZnktc2VsZjogY2VudGVyOwogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBh
bGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAgICAgICAgICAgZ2Fw
OiA0cHg7CiAgICAgICAgICAgIG1pbi13aWR0aDogMXB4OyAvKiBrZWVwIGNlbnRlciBjb2x1bW4gZXZl
biB3aGVuIGV4cGFuZCBpcyBoaWRkZW4gKi8KICAgICAgICB9CiAgICAgICAgLmktbWV0YS1yaWdodCB7
CiAgICAgICAgICAgIGp1c3RpZnktc2VsZjogZW5kOwogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBh
bGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDVweDsgZmxleC13cmFwOiBub3dyYXA7CiAgICAgICAgICAg
IGp1c3RpZnktY29udGVudDogZmxleC1lbmQ7CiAgICAgICAgICAgIG1pbi13aWR0aDogMDsKICAgICAg
ICB9CiAgICAgICAgLmktbWV0YS1yaWdodC50ZXh0LW1ldGEgewogICAgICAgICAgICBmbGV4LXdyYXA6
IG5vd3JhcDsKICAgICAgICAgICAgZ2FwOiA0cHg7CiAgICAgICAgfQogICAgICAgIC5pLXNyYy10aXRs
ZSB7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTBweDsKICAgICAgICAgICAgY29sb3I6IHZhcigtLXR4
dDMpOwogICAgICAgICAgICBtYXgtd2lkdGg6IDExZW07CiAgICAgICAgICAgIG92ZXJmbG93OiBoaWRk
ZW47CiAgICAgICAgICAgIHRleHQtb3ZlcmZsb3c6IGVsbGlwc2lzOwogICAgICAgICAgICB3aGl0ZS1z
cGFjZTogbm93cmFwOwogICAgICAgICAgICBtaW4td2lkdGg6IDA7CiAgICAgICAgICAgIGxpbmUtaGVp
Z2h0OiAxLjQ7CiAgICAgICAgfQogICAgICAgIC5pLXRpbWUsIC5pLXRhZyB7IGZvbnQtc2l6ZTogMTBw
eDsgY29sb3I6IHZhcigtLXR4dDMpOyB9CiAgICAgICAgLmktdGFnIHsKICAgICAgICAgICAgYmFja2dy
b3VuZDogI2YxZjNmODsgcGFkZGluZzogMCA1cHg7IGJvcmRlci1yYWRpdXM6IDNweDsKICAgICAgICAg
ICAgd2hpdGUtc3BhY2U6IG5vd3JhcDsgZmxleC1zaHJpbms6IDA7IGxpbmUtaGVpZ2h0OiAxLjQ7CiAg
ICAgICAgfQogICAgICAgIC5pLWNoYXJzIHsKICAgICAgICAgICAgZm9udC1zaXplOiAxMHB4OyBjb2xv
cjogdmFyKC0tdHh0Myk7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNmMWYzZjg7IHBhZGRpbmc6IDAg
NXB4OyBib3JkZXItcmFkaXVzOiAzcHg7CiAgICAgICAgICAgIGZvbnQtdmFyaWFudC1udW1lcmljOiB0
YWJ1bGFyLW51bXM7CiAgICAgICAgICAgIHdoaXRlLXNwYWNlOiBub3dyYXA7CiAgICAgICAgICAgIGRp
c3BsYXk6IGlubGluZS1mbGV4OyBhbGlnbi1pdGVtczogYmFzZWxpbmU7IGdhcDogMnB4OwogICAgICAg
IH0KICAgICAgICAuaS1jaGFycyAubiB7CiAgICAgICAgICAgIGRpc3BsYXk6IGlubGluZS1ibG9jazsK
ICAgICAgICAgICAgbWluLXdpZHRoOiA0Y2g7CiAgICAgICAgICAgIHRleHQtYWxpZ246IHJpZ2h0Owog
ICAgICAgICAgICBmb250LWZhbWlseTogJ0Nhc2NhZGlhIE1vbm8nLCAnQ29uc29sYXMnLCAnU2FyYXNh
IE1vbm8gU0MnLCB1aS1tb25vc3BhY2UsIG1vbm9zcGFjZTsKICAgICAgICAgICAgZm9udC13ZWlnaHQ6
IDYwMDsKICAgICAgICAgICAgY29sb3I6IHZhcigtLXR4dDIpOwogICAgICAgIH0KICAgICAgICAvKiBz
cmMtdGl0bGUtdGlwICovCiAgICAgICAgLmktc3JjLWljbywgLm1nLXNyYyB7IGN1cnNvcjogcG9pbnRl
cjsgfQogICAgICAgICNzcmMtdGlwIHsKICAgICAgICAgICAgcG9zaXRpb246IGZpeGVkOyB6LWluZGV4
OiA5OTk5OTsKICAgICAgICAgICAgbWF4LXdpZHRoOiBtaW4oMjgwcHgsIGNhbGMoMTAwdncgLSAxNnB4
KSk7CiAgICAgICAgICAgIHBhZGRpbmc6IDZweCAxMHB4OwogICAgICAgICAgICBib3JkZXItcmFkaXVz
OiA4cHg7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoMzIsMzYsNDgsLjkyKTsgY29sb3I6ICNm
ZmY7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTJweDsgbGluZS1oZWlnaHQ6IDEuMzU7CiAgICAgICAg
ICAgIGJveC1zaGFkb3c6IDAgNnB4IDE4cHggcmdiYSgwLDAsMCwuMjIpOwogICAgICAgICAgICBwb2lu
dGVyLWV2ZW50czogbm9uZTsKICAgICAgICAgICAgb3BhY2l0eTogMDsgdHJhbnNmb3JtOiB0cmFuc2xh
dGVZKDRweCk7CiAgICAgICAgICAgIHRyYW5zaXRpb246IG9wYWNpdHkgLjJzIGVhc2UsIHRyYW5zZm9y
bSAuMjJzIGN1YmljLWJlemllciguMjIsMSwuMzYsMSk7CiAgICAgICAgICAgIHdvcmQtYnJlYWs6IGJy
ZWFrLXdvcmQ7CiAgICAgICAgfQogICAgICAgICNzcmMtdGlwLnNob3cgeyBvcGFjaXR5OiAxOyB0cmFu
c2Zvcm06IHRyYW5zbGF0ZVkoMCk7IH0KICAgICAgICAuaS1zcmMtaWNvIHsKICAgICAgICAgICAgd2lk
dGg6IDE0cHg7IGhlaWdodDogMTRweDsgZmxleC1zaHJpbms6IDA7CiAgICAgICAgICAgIGJvcmRlci1y
YWRpdXM6IDJweDsgb2JqZWN0LWZpdDogY29udGFpbjsKICAgICAgICAgICAgZGlzcGxheTogYmxvY2s7
CiAgICAgICAgfQogICAgICAgIC5pLW51bSB7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGZsZXgt
ZGlyZWN0aW9uOiBjb2x1bW47IGFsaWduLWl0ZW1zOiBmbGV4LWVuZDsKICAgICAgICAgICAganVzdGlm
eS1jb250ZW50OiBzcGFjZS1iZXR3ZWVuOwogICAgICAgICAgICBhbGlnbi1zZWxmOiBzdHJldGNoOwog
ICAgICAgICAgICBmb250LXNpemU6IDEwcHg7IGNvbG9yOiB2YXIoLS10eHQzKTsgbWluLXdpZHRoOiAx
NnB4OwogICAgICAgICAgICB0ZXh0LWFsaWduOiByaWdodDsgZmxleC1zaHJpbms6IDA7CiAgICAgICAg
ICAgIHBhZGRpbmctdG9wOiAycHg7CiAgICAgICAgfQogICAgICAgIC5pLW51bSAuaS1zcmMtaWNvIHsg
d2lkdGg6IDE2cHg7IGhlaWdodDogMTZweDsgbWFyZ2luLXRvcDogYXV0bzsgfQoKICAgICAgICAuaS1l
eHBhbmQtYnRuIHsKICAgICAgICAgICAgYm9yZGVyOiBub25lOyBiYWNrZ3JvdW5kOiBub25lOyBjdXJz
b3I6IHBvaW50ZXI7CiAgICAgICAgICAgIGNvbG9yOiB2YXIoLS10eHQzKTsgZm9udC1zaXplOiAxMnB4
OyBwYWRkaW5nOiAzcHggMTBweDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogOHB4OyBkaXNwbGF5
OiBub25lOyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDRweDsKICAgICAgICAgICAgdHJhbnNpdGlv
bjogY29sb3IgdmFyKC0tdHIpLCBiYWNrZ3JvdW5kIHZhcigtLXRyKTsKICAgICAgICAgICAgLXdlYmtp
dC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgICAgICBsaW5l
LWhlaWdodDogMS4yOwogICAgICAgIH0KICAgICAgICAuaS1leHBhbmQtYnRuIHN2ZyB7IHdpZHRoOiAx
NHB4OyBoZWlnaHQ6IDE0cHg7IGZsZXgtc2hyaW5rOiAwOyB9CiAgICAgICAgLmktZXhwYW5kLWJ0bi5v
biB7IGRpc3BsYXk6IGlubGluZS1mbGV4OyB9CiAgICAgICAgLmktZXhwYW5kLWJ0bjpob3ZlciB7IGNv
bG9yOiB2YXIoLS1hY2MpOyBiYWNrZ3JvdW5kOiByZ2JhKDkxLDExNSwyMzIsLjA4KTsgfQogICAgICAg
IC5pLXByZXYuZXhwYW5kZWQsIC5pLW5hbWUuZXhwYW5kZWQgewogICAgICAgICAgICAtd2Via2l0LWxp
bmUtY2xhbXA6IHVuc2V0OwogICAgICAgICAgICBkaXNwbGF5OiBibG9jazsKICAgICAgICAgICAgb3Zl
cmZsb3c6IGhpZGRlbjsKICAgICAgICAgICAgLyog6auY5bqm55SxIEpTIOaMieWIl+ihqOWPr+inhuWM
uuiuvuWumu+8mue6puWNoOaVtOihqOWwkeS4gOihjCAqLwogICAgICAgIH0KICAgICAgICAuaS1zcmMt
dGl0bGUgeyBkaXNwbGF5OiBub25lICFpbXBvcnRhbnQ7IH0KICAgICAgICAuaS1maWxlLWRldGFpbCB7
CiAgICAgICAgICAgIGRpc3BsYXk6IG5vbmU7CiAgICAgICAgICAgIG1hcmdpbi10b3A6IDRweDsKICAg
ICAgICAgICAgcGFkZGluZzogMDsKICAgICAgICAgICAgYmFja2dyb3VuZDogbm9uZTsKICAgICAgICAg
ICAgYm9yZGVyOiBub25lOwogICAgICAgIH0KICAgICAgICAuaS1maWxlLWRldGFpbC5vbiB7IGRpc3Bs
YXk6IGJsb2NrOyB9CiAgICAgICAgLmZkLWJsb2NrIHsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsg
ZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgZ2FwOiA2cHg7CiAgICAgICAgfQogICAgICAgIC5mZC1ibG9j
ayArIC5mZC1ibG9jayB7IG1hcmdpbi10b3A6IDhweDsgfQogICAgICAgIC5mZC1wYXRoIHsKICAgICAg
ICAgICAgd2lkdGg6IDEwMCU7CiAgICAgICAgICAgIGZvbnQ6IDYwMCAxMnB4LzEuNTUgJ1NlZ29lIFVJ
IFZhcmlhYmxlIFRleHQnLCdTZWdvZSBVSScsJ01pY3Jvc29mdCBZYUhlaSBVSScsc2Fucy1zZXJpZjsK
ICAgICAgICAgICAgY29sb3I6IHZhcigtLXR4dDIpOwogICAgICAgICAgICBsZXR0ZXItc3BhY2luZzog
LjAxZW07CiAgICAgICAgICAgIHdvcmQtYnJlYWs6IGJyZWFrLWFsbDsKICAgICAgICAgICAgdXNlci1z
ZWxlY3Q6IHRleHQ7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJl
Z2lvbjogbm8tZHJhZzsKICAgICAgICB9CiAgICAgICAgLmZkLXBhdGgubGl2ZSB7IGN1cnNvcjogcG9p
bnRlcjsgfQogICAgICAgIC5mZC1wYXRoLmxpdmU6aG92ZXIgeyBjb2xvcjogdmFyKC0tYWNjKTsgfQog
ICAgICAgIC5mZC1wYXRoLmRlYWQgewogICAgICAgICAgICBjb2xvcjogIzlhYTBiMDsKICAgICAgICAg
ICAgdGV4dC1kZWNvcmF0aW9uOiBsaW5lLXRocm91Z2g7CiAgICAgICAgICAgIHRleHQtZGVjb3JhdGlv
bi10aGlja25lc3M6IDJweDsKICAgICAgICAgICAgdGV4dC1kZWNvcmF0aW9uLWNvbG9yOiByZ2JhKDE1
NCwgMTYwLCAxNzYsIC41NSk7CiAgICAgICAgICAgIHRleHQtZGVjb3JhdGlvbi1za2lwLWluazogbm9u
ZTsKICAgICAgICAgICAgY3Vyc29yOiBkZWZhdWx0OwogICAgICAgIH0KICAgICAgICAuZmQtYWN0aW9u
cyB7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnkt
Y29udGVudDogZmxleC1lbmQ7CiAgICAgICAgICAgIGdhcDogOHB4OyBmbGV4LXdyYXA6IHdyYXA7CiAg
ICAgICAgfQogICAgICAgIC5mZC1idG4gewogICAgICAgICAgICBib3JkZXI6IG5vbmU7IGJhY2tncm91
bmQ6IG5vbmU7IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICAgICAgY29sb3I6IHZhcigtLXR4dDMpOyBm
b250LXNpemU6IDEwcHg7IGZvbnQtd2VpZ2h0OiA2MDA7CiAgICAgICAgICAgIHBhZGRpbmc6IDFweCAy
cHg7IGRpc3BsYXk6IGlubGluZS1mbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDJweDsKICAg
ICAgICAgICAgd2hpdGUtc3BhY2U6IG5vd3JhcDsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9u
OiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgICAgICB0cmFuc2l0aW9uOiBjb2xv
ciB2YXIoLS10cik7CiAgICAgICAgfQogICAgICAgIC5mZC1idG46aG92ZXIgeyBjb2xvcjogdmFyKC0t
YWNjKTsgfQogICAgICAgIC5mZC1idG4ub2sgeyBjb2xvcjogIzFmN2E1NTsgfQoKICAgICAgICAvKiDi
lIDilIAgQ29udGV4dCBtZW51IOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgCAqLwog
ICAgICAgICNjdHggewogICAgICAgICAgICBwb3NpdGlvbjogZml4ZWQ7IHotaW5kZXg6IDk5OTk7IG1p
bi13aWR0aDogMTMycHg7IGRpc3BsYXk6IG5vbmU7IHBhZGRpbmc6IDRweDsKICAgICAgICAgICAgYmFj
a2dyb3VuZDogI2ZmZjsgYm9yZGVyLXJhZGl1czogdmFyKC0tcik7IGJveC1zaGFkb3c6IDAgNnB4IDE2
cHggcmdiYSgwLDAsMCwuMTQpOwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7
IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgfQogICAgICAgICNjdHgub24geyBkaXNwbGF5OiBi
bG9jazsgfQogICAgICAgIC5jLWl0ZW0gewogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1p
dGVtczogY2VudGVyOyBnYXA6IDdweDsgcGFkZGluZzogNnB4IDlweDsKICAgICAgICAgICAgYm9yZGVy
LXJhZGl1czogdmFyKC0tcik7IGN1cnNvcjogcG9pbnRlcjsgZm9udC1zaXplOiAxMXB4OyBjb2xvcjog
dmFyKC0tdHh0KTsKICAgICAgICB9CiAgICAgICAgLmMtaXRlbTpob3ZlciB7IGJhY2tncm91bmQ6ICNm
MmY0Zjk7IH0KICAgICAgICAuYy1pdGVtLmRhbmdlciB7IGNvbG9yOiAjZmY3YjljOyB9CiAgICAgICAg
LmMtc2VwIHsgaGVpZ2h0OiAxcHg7IGJhY2tncm91bmQ6ICNlY2VmZjU7IG1hcmdpbjogM3B4IDA7IH0K
ICAgICAgICAuYy1pY28geyB3aWR0aDogMTRweDsgdGV4dC1hbGlnbjogY2VudGVyOyB9CgogICAgICAg
IC8qIOKUgOKUgCBDbGVhciBjb25maXJtIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgCAq
LwogICAgICAgICNjbHItZGxnIHsKICAgICAgICAgICAgZGlzcGxheTogbm9uZTsgcG9zaXRpb246IGZp
eGVkOyBpbnNldDogMDsgei1pbmRleDogMTAwMDA7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEo
MjAsIDIyLCAzNSwgLjQyKTsKICAgICAgICAgICAgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1j
b250ZW50OiBjZW50ZXI7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBw
LXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICB9CiAgICAgICAgI2Nsci1kbGcub24geyBkaXNwbGF5OiBm
bGV4OyB9CiAgICAgICAgLmNsci1ib3ggewogICAgICAgICAgICB3aWR0aDogbWluKDI4MHB4LCBjYWxj
KDEwMCUgLSAzMnB4KSk7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNmZmY7IGJvcmRlci1yYWRpdXM6
IDEycHg7CiAgICAgICAgICAgIGJveC1zaGFkb3c6IDAgMTJweCAzMnB4IHJnYmEoMCwwLDAsLjE4KTsK
ICAgICAgICAgICAgcGFkZGluZzogMTZweCAxNnB4IDE0cHg7IGNvbG9yOiB2YXIoLS10eHQpOwogICAg
ICAgIH0KICAgICAgICAuY2xyLXRpdGxlIHsgZm9udC1zaXplOiAxNHB4OyBmb250LXdlaWdodDogNzAw
OyBtYXJnaW4tYm90dG9tOiA2cHg7IH0KICAgICAgICAuY2xyLWRlc2MgeyBmb250LXNpemU6IDExcHg7
IGNvbG9yOiB2YXIoLS10eHQzKTsgbGluZS1oZWlnaHQ6IDEuNTsgbWFyZ2luLWJvdHRvbTogMTJweDsg
fQogICAgICAgIC5jbHItY2hlY2sgewogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVt
czogY2VudGVyOyBnYXA6IDdweDsKICAgICAgICAgICAgZm9udC1zaXplOiAxMnB4OyBjb2xvcjogdmFy
KC0tdHh0KTsgY3Vyc29yOiBwb2ludGVyOwogICAgICAgICAgICB1c2VyLXNlbGVjdDogbm9uZTsgbWFy
Z2luLWJvdHRvbTogMTRweDsKICAgICAgICB9CiAgICAgICAgLmNsci1jaGVjayBpbnB1dCB7CiAgICAg
ICAgICAgIHdpZHRoOiAxNHB4OyBoZWlnaHQ6IDE0cHg7IGFjY2VudC1jb2xvcjogdmFyKC0tYWNjKTsg
Y3Vyc29yOiBwb2ludGVyOwogICAgICAgIH0KICAgICAgICAuY2xyLWJ0bnMgeyBkaXNwbGF5OiBmbGV4
OyBnYXA6IDhweDsganVzdGlmeS1jb250ZW50OiBmbGV4LWVuZDsgfQogICAgICAgIC5jbHItYnRucyBi
dXR0b24gewogICAgICAgICAgICBib3JkZXI6IG5vbmU7IGJvcmRlci1yYWRpdXM6IDhweDsgcGFkZGlu
ZzogN3B4IDE0cHg7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTJweDsgY3Vyc29yOiBwb2ludGVyOyBm
b250LXdlaWdodDogNjAwOwogICAgICAgICAgICB0cmFuc2l0aW9uOiBiYWNrZ3JvdW5kIHZhcigtLXRy
KSwgY29sb3IgdmFyKC0tdHIpOwogICAgICAgIH0KICAgICAgICAjY2xyLWNhbmNlbCB7IGJhY2tncm91
bmQ6ICNmMWYzZjg7IGNvbG9yOiB2YXIoLS10eHQyKTsgfQogICAgICAgICNjbHItY2FuY2VsOmhvdmVy
IHsgYmFja2dyb3VuZDogI2U2ZTlmMjsgfQogICAgICAgICNjbHItb2sgeyBiYWNrZ3JvdW5kOiByZ2Jh
KDI1NSwxMjMsMTU2LC4xNCk7IGNvbG9yOiAjZTg1YTdhOyB9CiAgICAgICAgI2Nsci1vazpob3ZlciB7
IGJhY2tncm91bmQ6IHJnYmEoMjU1LDEyMywxNTYsLjI0KTsgfQoKICAgICAgICAvKiDilIDilIAgRmls
ZSBwYXRoIHRpcCDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAgKi8KICAgICAgICAjcGF0
aC10aXAgewogICAgICAgICAgICBkaXNwbGF5OiBub25lOyBwb3NpdGlvbjogZml4ZWQ7IHotaW5kZXg6
IDEwMDAxOwogICAgICAgICAgICB3aWR0aDogbWluKDMyMHB4LCBjYWxjKDEwMHZ3IC0gMTZweCkpOwog
ICAgICAgICAgICBtYXgtaGVpZ2h0OiBtaW4oMjgwcHgsIGNhbGMoMTAwdmggLSAyNHB4KSk7CiAgICAg
ICAgICAgIG92ZXJmbG93OiBhdXRvOwogICAgICAgICAgICBwYWRkaW5nOiAwOwogICAgICAgICAgICBi
YWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGllbnQoMTY1ZGVnLCAjZmZmZmZmIDAlLCAjZjZmOGZjIDEwMCUp
OwogICAgICAgICAgICBib3JkZXI6IDFweCBzb2xpZCByZ2JhKDcwLCA4NCwgMTIwLCAuMSk7CiAgICAg
ICAgICAgIGJvcmRlci1yYWRpdXM6IDEycHg7CiAgICAgICAgICAgIGJveC1zaGFkb3c6CiAgICAgICAg
ICAgICAgICAwIDRweCA2cHggcmdiYSgzMCwgNDAsIDcwLCAuMDQpLAogICAgICAgICAgICAgICAgMCAx
NHB4IDM2cHggcmdiYSgzMCwgNDAsIDcwLCAuMTYpOwogICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0
KTsKICAgICAgICAgICAgcG9pbnRlci1ldmVudHM6IGF1dG87CiAgICAgICAgICAgIG9wYWNpdHk6IDA7
CiAgICAgICAgICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlWSg0cHgpIHNjYWxlKC45OCk7CiAgICAgICAg
ICAgIHRyYW5zaXRpb246IG9wYWNpdHkgLjE0cyBlYXNlLCB0cmFuc2Zvcm0gLjE0cyBlYXNlOwogICAg
ICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAg
ICAgICAgfQogICAgICAgICNwYXRoLXRpcC5vbiB7CiAgICAgICAgICAgIGRpc3BsYXk6IGJsb2NrOwog
ICAgICAgICAgICBvcGFjaXR5OiAxOwogICAgICAgICAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoMCkg
c2NhbGUoMSk7CiAgICAgICAgfQogICAgICAgIC5wdC1oZWFkIHsKICAgICAgICAgICAgZGlzcGxheTog
ZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBzcGFjZS1iZXR3ZWVuOwog
ICAgICAgICAgICBnYXA6IDEwcHg7IHBhZGRpbmc6IDEwcHggMTJweCA4cHg7CiAgICAgICAgICAgIGJv
cmRlci1ib3R0b206IDFweCBzb2xpZCByZ2JhKDcwLCA4NCwgMTIwLCAuMDcpOwogICAgICAgIH0KICAg
ICAgICAucHQtdGl0bGUgewogICAgICAgICAgICBmb250LXNpemU6IDExcHg7IGZvbnQtd2VpZ2h0OiA3
MDA7IGxldHRlci1zcGFjaW5nOiAuMDRlbTsKICAgICAgICAgICAgY29sb3I6IHZhcigtLXR4dDIpOyB0
ZXh0LXRyYW5zZm9ybTogdXBwZXJjYXNlOwogICAgICAgICAgICBmbGV4LXNocmluazogMDsKICAgICAg
ICB9CiAgICAgICAgLnB0LWhlYWQtYnRuIHsKICAgICAgICAgICAgZmxleC1zaHJpbms6IDA7IG1hcmdp
bi1sZWZ0OiBhdXRvOwogICAgICAgICAgICBoZWlnaHQ6IDIycHg7IHBhZGRpbmc6IDAgOHB4OyBkaXNw
bGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA0cHg7CiAgICAgICAgICAg
IGJvcmRlcjogMXB4IHNvbGlkIHJnYmEoMTA3LDExMiwxMjgsLjIyKTsgYm9yZGVyLXJhZGl1czogNnB4
OyBjdXJzb3I6IHBvaW50ZXI7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoMTA3LDExMiwxMjgs
LjA2KTsgY29sb3I6ICM4YTkwYTA7IGZvbnQtc2l6ZTogMTFweDsgZm9udC13ZWlnaHQ6IDYwMDsKICAg
ICAgICAgICAgd2hpdGUtc3BhY2U6IG5vd3JhcDsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9u
OiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgICAgICB0cmFuc2l0aW9uOiBiYWNr
Z3JvdW5kIHZhcigtLXRyKSwgY29sb3IgdmFyKC0tdHIpLCBib3JkZXItY29sb3IgdmFyKC0tdHIpOwog
ICAgICAgIH0KICAgICAgICAucHQtaGVhZC1idG46aG92ZXIgewogICAgICAgICAgICBiYWNrZ3JvdW5k
OiByZ2JhKDEwNywxMTIsMTI4LC4xMik7IGNvbG9yOiB2YXIoLS10eHQyKTsKICAgICAgICAgICAgYm9y
ZGVyLWNvbG9yOiByZ2JhKDEwNywxMTIsMTI4LC40KTsKICAgICAgICB9CiAgICAgICAgLnB0LWxpc3Qg
eyBwYWRkaW5nOiA2cHggOHB4IDhweDsgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVt
bjsgZ2FwOiA0cHg7IH0KICAgICAgICAucHQtcm93IHsKICAgICAgICAgICAgZGlzcGxheTogZ3JpZDsg
Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiA4cHggMWZyOyBnYXA6IDhweDsKICAgICAgICAgICAgcGFkZGlu
ZzogOHB4IDhweDsgYm9yZGVyLXJhZGl1czogOHB4OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2Jh
KDI1NSwyNTUsMjU1LC43KTsKICAgICAgICB9CiAgICAgICAgLnB0LXJvdy5kZWFkIHsgYmFja2dyb3Vu
ZDogcmdiYSgyNTUsIDEyMywgMTU2LCAuMDYpOyB9CiAgICAgICAgLnB0LWRvdCB7CiAgICAgICAgICAg
IHdpZHRoOiA4cHg7IGhlaWdodDogOHB4OyBib3JkZXItcmFkaXVzOiA1MCU7IG1hcmdpbi10b3A6IDVw
eDsKICAgICAgICAgICAgYmFja2dyb3VuZDogIzJlYjQ3ODsgYm94LXNoYWRvdzogMCAwIDAgM3B4IHJn
YmEoNDYsIDE4MCwgMTIwLCAuMTgpOwogICAgICAgIH0KICAgICAgICAucHQtcm93LmRlYWQgLnB0LWRv
dCB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNlODVhN2E7IGJveC1zaGFkb3c6IDAgMCAwIDNweCBy
Z2JhKDIzMiwgOTAsIDEyMiwgLjE2KTsKICAgICAgICB9CiAgICAgICAgLnB0LW5hbWUgewogICAgICAg
ICAgICBmb250LXNpemU6IDEycHg7IGZvbnQtd2VpZ2h0OiA2NTA7IGNvbG9yOiB2YXIoLS10eHQpOwog
ICAgICAgICAgICBsaW5lLWhlaWdodDogMS4zOyB3b3JkLWJyZWFrOiBicmVhay1hbGw7CiAgICAgICAg
fQogICAgICAgIC5wdC1wYXRoIHsKICAgICAgICAgICAgbWFyZ2luLXRvcDogM3B4OwogICAgICAgICAg
ICBmb250OiAxMC41cHgvMS40NSAnQ2FzY2FkaWEgTW9ubycsJ0NvbnNvbGFzJywnTWljcm9zb2Z0IFlh
SGVpIFVJJyxtb25vc3BhY2U7CiAgICAgICAgICAgIGNvbG9yOiB2YXIoLS10eHQyKTsgd29yZC1icmVh
azogYnJlYWstYWxsOwogICAgICAgICAgICB1c2VyLXNlbGVjdDogdGV4dDsKICAgICAgICB9CiAgICAg
ICAgLnB0LXBhdGgubGl2ZSB7CiAgICAgICAgICAgIGNvbG9yOiB2YXIoLS1hY2MpOyBjdXJzb3I6IHBv
aW50ZXI7CiAgICAgICAgfQogICAgICAgIC5wdC1wYXRoLmxpdmU6aG92ZXIgeyB0ZXh0LWRlY29yYXRp
b246IHVuZGVybGluZTsgfQogICAgICAgIC5wdC1wYXRoLmRlYWQgewogICAgICAgICAgICBjb2xvcjog
I2M0M2Q1YzsKICAgICAgICAgICAgdGV4dC1kZWNvcmF0aW9uOiBsaW5lLXRocm91Z2g7CiAgICAgICAg
ICAgIHRleHQtZGVjb3JhdGlvbi10aGlja25lc3M6IDJweDsKICAgICAgICAgICAgdGV4dC1kZWNvcmF0
aW9uLWNvbG9yOiAjZTExZDQ4OwogICAgICAgICAgICBjdXJzb3I6IGRlZmF1bHQ7CiAgICAgICAgfQog
ICAgICAgIC5wdC1hY3Rpb25zIHsKICAgICAgICAgICAgbWFyZ2luLXRvcDogNnB4OwogICAgICAgICAg
ICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDZweDsgZmxleC13cmFwOiB3
cmFwOwogICAgICAgIH0KICAgICAgICAucHQtY29weS1idG4gewogICAgICAgICAgICBoZWlnaHQ6IDIy
cHg7IHBhZGRpbmc6IDAgOHB4OyBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGNlbnRl
cjsKICAgICAgICAgICAgYm9yZGVyOiAxcHggc29saWQgcmdiYSgxMDcsMTEyLDEyOCwuMjIpOyBib3Jk
ZXItcmFkaXVzOiA2cHg7IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICAgICAgYmFja2dyb3VuZDogcmdi
YSgxMDcsMTEyLDEyOCwuMDYpOyBjb2xvcjogIzhhOTBhMDsgZm9udC1zaXplOiAxMXB4OyBmb250LXdl
aWdodDogNjAwOwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdp
b246IG5vLWRyYWc7CiAgICAgICAgICAgIHRyYW5zaXRpb246IGJhY2tncm91bmQgdmFyKC0tdHIpLCBj
b2xvciB2YXIoLS10ciksIGJvcmRlci1jb2xvciB2YXIoLS10cik7CiAgICAgICAgfQogICAgICAgIC5w
dC1jb3B5LWJ0bjpob3ZlciB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoMTA3LDExMiwxMjgs
LjEyKTsgY29sb3I6IHZhcigtLXR4dDIpOwogICAgICAgICAgICBib3JkZXItY29sb3I6IHJnYmEoMTA3
LDExMiwxMjgsLjQpOwogICAgICAgIH0KICAgICAgICAucHQtY29weS1idG4ub2sgewogICAgICAgICAg
ICBjb2xvcjogIzFmN2E1NTsgYm9yZGVyLWNvbG9yOiByZ2JhKDQ2LCAxODAsIDEyMCwgLjM1KTsKICAg
ICAgICAgICAgYmFja2dyb3VuZDogcmdiYSg0NiwgMTgwLCAxMjAsIC4xKTsKICAgICAgICB9CiAgICAg
ICAgLml0bS5pdC1ncm91cCB7CiAgICAgICAgICAgIGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47CiAgICAg
ICAgICAgIGFsaWduLWl0ZW1zOiBzdHJldGNoOwogICAgICAgICAgICBnYXA6IDA7CiAgICAgICAgICAg
IHBhZGRpbmc6IDZweCA4cHggNHB4OwogICAgICAgICAgICBjdXJzb3I6IGRlZmF1bHQ7CiAgICAgICAg
fQogICAgICAgIC5pdG0uaXQtZ3JvdXA6aG92ZXIgeyBiYWNrZ3JvdW5kOiB2YXIoLS1jYXJkKTsgfQog
ICAgICAgIC5tZy1oZWFkIHsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNl
bnRlcjsgZ2FwOiA2cHg7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTFweDsgY29sb3I6IHZhcigtLXR4
dDMpOyBmb250LXdlaWdodDogNjAwOwogICAgICAgICAgICBwYWRkaW5nOiAycHggMnB4IDZweDsgdXNl
ci1zZWxlY3Q6IG5vbmU7CiAgICAgICAgfQogICAgICAgIC5tZy1oZWFkIC5tZy10YWcgewogICAgICAg
ICAgICBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsKICAgICAgICAgICAg
aGVpZ2h0OiAxNnB4OyBwYWRkaW5nOiAwIDZweDsgYm9yZGVyLXJhZGl1czogOHB4OwogICAgICAgICAg
ICBiYWNrZ3JvdW5kOiByZ2JhKDkxLDExNSwyMzIsLjEyKTsgY29sb3I6IHZhcigtLWFjYyk7IGZvbnQt
c2l6ZTogMTBweDsKICAgICAgICB9CiAgICAgICAgLm1nLXJvdyB7CiAgICAgICAgICAgIHBhZGRpbmc6
IDdweCA2cHg7IG1hcmdpbi1ib3R0b206IDNweDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogNXB4
OyBjdXJzb3I6IHBvaW50ZXI7CiAgICAgICAgICAgIGJvcmRlcjogMXB4IHNvbGlkIHRyYW5zcGFyZW50
OwogICAgICAgICAgICB0cmFuc2l0aW9uOiBiYWNrZ3JvdW5kIC4xMnMgZWFzZSwgYm9yZGVyLWNvbG9y
IC4xMnMgZWFzZTsKICAgICAgICB9CiAgICAgICAgLm1nLXJvdzpob3ZlciB7IGJhY2tncm91bmQ6IHZh
cigtLWNhcmQtaCk7IH0KICAgICAgICAubWctcm93LnNlbCB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6
ICNlZGYxZmY7CiAgICAgICAgICAgIGJvcmRlci1jb2xvcjogcmdiYSg5MSwxMTUsMjMyLC4zNSk7CiAg
ICAgICAgICAgIGJveC1zaGFkb3c6IDAgMCAwIDFweCByZ2JhKDkxLDExNSwyMzIsLjI1KTsKICAgICAg
ICB9CiAgICAgICAgLm1nLXJvdy5tdWx0aSB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNlZWYyZmY7
CiAgICAgICAgICAgIGJvcmRlci1jb2xvcjogcmdiYSg5MSwxMTUsMjMyLC40NSk7CiAgICAgICAgfQog
ICAgICAgIC5tZy10aXRsZSB7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTNweDsgZm9udC13ZWlnaHQ6
IDYwMDsgY29sb3I6IHZhcigtLWFjYyk7CiAgICAgICAgICAgIG1hcmdpbi1ib3R0b206IDJweDsgbGlu
ZS1oZWlnaHQ6IDEuMzU7CiAgICAgICAgICAgIGRpc3BsYXk6IC13ZWJraXQtYm94OyAtd2Via2l0LWJv
eC1vcmllbnQ6IHZlcnRpY2FsOyAtd2Via2l0LWxpbmUtY2xhbXA6IDI7CiAgICAgICAgICAgIG92ZXJm
bG93OiBoaWRkZW47IHdvcmQtYnJlYWs6IGJyZWFrLXdvcmQ7CiAgICAgICAgfQogICAgICAgIC5tZy1i
b2R5IHsKICAgICAgICAgICAgZm9udC1zaXplOiAxMi41cHg7IGZvbnQtd2VpZ2h0OiA1MDA7IGNvbG9y
OiB2YXIoLS10eHQpOwogICAgICAgICAgICB3aGl0ZS1zcGFjZTogcHJlLXdyYXA7IHdvcmQtYnJlYWs6
IGJyZWFrLWFsbDsKICAgICAgICAgICAgZGlzcGxheTogLXdlYmtpdC1ib3g7IC13ZWJraXQtYm94LW9y
aWVudDogdmVydGljYWw7IC13ZWJraXQtbGluZS1jbGFtcDogNDsKICAgICAgICAgICAgb3ZlcmZsb3c6
IGhpZGRlbjsgbGluZS1oZWlnaHQ6IDEuNDsKICAgICAgICB9CiAgICAgICAgLm1nLWJvZHkuaW1nIHsg
Y29sb3I6IHZhcigtLXR4dDIpOyB9CiAgICAgICAgLm1nLXJvdy10b3AgewogICAgICAgICAgICBkaXNw
bGF5OiBmbGV4OyBhbGlnbi1pdGVtczogZmxleC1zdGFydDsgZ2FwOiA4cHg7CiAgICAgICAgfQogICAg
ICAgIC5tZy1yb3ctbWFpbiB7IGZsZXg6IDE7IG1pbi13aWR0aDogMDsgfQogICAgICAgIC5tZy1zcmMg
ewogICAgICAgICAgICB3aWR0aDogMThweDsgaGVpZ2h0OiAxOHB4OyBmbGV4LXNocmluazogMDsgbWFy
Z2luLXRvcDogMnB4OwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiAzcHg7IG9iamVjdC1maXQ6IGNv
bnRhaW47CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoMCwwLDAsLjA0KTsKICAgICAgICB9CiAg
ICAgICAgLmktZmF2LXRpdGxlIHsKICAgICAgICAgICAgZm9udC1zaXplOiAxM3B4OyBmb250LXdlaWdo
dDogNjAwOyBjb2xvcjogdmFyKC0tYWNjKTsKICAgICAgICAgICAgbWFyZ2luOiAwIDAgM3B4OyBsaW5l
LWhlaWdodDogMS4zNTsKICAgICAgICAgICAgZGlzcGxheTogLXdlYmtpdC1ib3g7IC13ZWJraXQtYm94
LW9yaWVudDogdmVydGljYWw7IC13ZWJraXQtbGluZS1jbGFtcDogMjsKICAgICAgICAgICAgb3ZlcmZs
b3c6IGhpZGRlbjsgd29yZC1icmVhazogYnJlYWstd29yZDsKICAgICAgICB9CiAgICAgICAgI3RpdGxl
LWRsZyB7CiAgICAgICAgICAgIGRpc3BsYXk6IG5vbmU7IHBvc2l0aW9uOiBmaXhlZDsgaW5zZXQ6IDA7
IHotaW5kZXg6IDEwMDsKICAgICAgICAgICAgYmFja2dyb3VuZDogcmdiYSgxNSwxOCwyOCwuMzUpOwog
ICAgICAgICAgICBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAg
ICAgICB9CiAgICAgICAgI3RpdGxlLWRsZy5vbiB7IGRpc3BsYXk6IGZsZXg7IH0KICAgICAgICAjdGl0
bGUtZGxnIC50aXRsZS1ib3ggewogICAgICAgICAgICB3aWR0aDogMjYwcHg7IHBhZGRpbmc6IDE2cHgg
MTZweCAxMnB4OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiB2YXIoLS1jYXJkKTsgYm9yZGVyLXJhZGl1
czogMTBweDsKICAgICAgICAgICAgYm94LXNoYWRvdzogMCA4cHggMjhweCByZ2JhKDAsMCwwLC4xOCk7
CiAgICAgICAgfQogICAgICAgICN0aXRsZS1pbnB1dCB7CiAgICAgICAgICAgIHdpZHRoOiAxMDAlOyBi
b3gtc2l6aW5nOiBib3JkZXItYm94OyBtYXJnaW46IDhweCAwIDEycHg7CiAgICAgICAgICAgIGhlaWdo
dDogMzJweDsgcGFkZGluZzogMCAxMHB4OyBib3JkZXItcmFkaXVzOiA2cHg7CiAgICAgICAgICAgIGJv
cmRlcjogMXB4IHNvbGlkICNkNWRhZTY7IGJhY2tncm91bmQ6ICNmZmY7IGNvbG9yOiB2YXIoLS10eHQp
OwogICAgICAgICAgICBmb250LXNpemU6IDEzcHg7IG91dGxpbmU6IG5vbmU7CiAgICAgICAgfQogICAg
ICAgICN0aXRsZS1pbnB1dDpmb2N1cyB7IGJvcmRlci1jb2xvcjogdmFyKC0tYWNjKTsgfQoKICAgIAog
ICAgICAgIC8qIHVpLWdyYXktYmctdjEgKi8KICAgICAgICA6cm9vdCB7CiAgICAgICAgICAgIC0tYmc6
ICNlNGU3ZWUgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgaHRtbCwgYm9keSB7CiAgICAgICAg
ICAgIGJhY2tncm91bmQ6ICNlNGU3ZWUgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgI2FwcCB7
CiAgICAgICAgICAgIGJhY2tncm91bmQ6IGxpbmVhci1ncmFkaWVudCgxODBkZWcsICNlOWVjZjMgMCUs
ICNlMGU0ZWMgMTAwJSkgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgI2hkciB7CiAgICAgICAg
ICAgIGJhY2tncm91bmQ6ICNlMmU2ZWUgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgI3RhYnMg
ewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZTJlNmVlICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAg
ICAgICNsaXN0LCAjZW1wdHksICNza2VsLCAjaGRyLWdyb3csICNzZWFyY2gtd3JhcCB7CiAgICAgICAg
ICAgIGJhY2tncm91bmQ6IHRyYW5zcGFyZW50ICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgICNz
ZWFyY2gtYm94IHsKICAgICAgICAgICAgdHJhbnNmb3JtLW9yaWdpbjogcmlnaHQgY2VudGVyOwogICAg
ICAgICAgICBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudCAhaW1wb3J0YW50OwogICAgICAgIH0KICAgICAg
ICAuaXRtLCAubWcsIC5tZy1yb3csIC5tZXJnZS1ncm91cCB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6
ICNmZmZmZmYgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgLml0bTpob3ZlciB7CiAgICAgICAg
ICAgIGJhY2tncm91bmQ6ICNmOGY5ZmMgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAKICAgICAgICAv
KiBzZWwtdGludC1ibHVlLXYxICovCiAgICAgICAgLml0bS5zZWwsCiAgICAgICAgLm1nLXJvdy5zZWws
CiAgICAgICAgLml0bS5tdWx0aSwKICAgICAgICAubWctcm93Lm11bHRpLAogICAgICAgIC5pdG0ubXVs
dGkuc2VsLAogICAgICAgIC5pdC1ncm91cC5zZWwsCiAgICAgICAgLml0LWdyb3VwLm11bHRpIHsKICAg
ICAgICAgICAgYmFja2dyb3VuZDogI2U4ZWZmZiAhaW1wb3J0YW50OwogICAgICAgIH0KICAgICAgICAu
aXRtLnNlbDpob3ZlciwKICAgICAgICAuaXRtLm11bHRpOmhvdmVyLAogICAgICAgIC5tZy1yb3cuc2Vs
OmhvdmVyLAogICAgICAgIC5tZy1yb3cubXVsdGk6aG92ZXIgewogICAgICAgICAgICBiYWNrZ3JvdW5k
OiAjZGRlNmZmICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgCiAgICAgICAgLyogaG92ZXItZ3JlZW4t
cmlzZS12MiAqLwogICAgICAgIC8qIGhvdmVyLWFjY2VudC1yaXNlLXYzICovCiAgICAgICAgLml0bSB7
IHBvc2l0aW9uOiByZWxhdGl2ZSAhaW1wb3J0YW50OyBvdmVyZmxvdzogaGlkZGVuICFpbXBvcnRhbnQ7
IH0KICAgICAgICAuaXRtOjpiZWZvcmUgewogICAgICAgICAgICBjb250ZW50OiAiIiAhaW1wb3J0YW50
OwogICAgICAgICAgICBwb3NpdGlvbjogYWJzb2x1dGUgIWltcG9ydGFudDsKICAgICAgICAgICAgbGVm
dDogMCAhaW1wb3J0YW50OyByaWdodDogMCAhaW1wb3J0YW50OyBib3R0b206IDAgIWltcG9ydGFudDsK
ICAgICAgICAgICAgaGVpZ2h0OiAwICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIHBvaW50ZXItZXZlbnRz
OiBub25lICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIHotaW5kZXg6IDAgIWltcG9ydGFudDsKICAgICAg
ICAgICAgYm9yZGVyLXJhZGl1czogMCAwIHZhcigtLXIsIDRweCkgdmFyKC0tciwgNHB4KSAhaW1wb3J0
YW50OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGllbnQodG8gdG9wLAogICAgICAg
ICAgICAgICAgcmdiYSg5MSwgMTE1LCAyMzIsIC4zMikgMCUsCiAgICAgICAgICAgICAgICByZ2JhKDkx
LCAxMTUsIDIzMiwgLjEyKSA1NSUsCiAgICAgICAgICAgICAgICByZ2JhKDkxLCAxMTUsIDIzMiwgMCkg
MTAwJSkgIWltcG9ydGFudDsKICAgICAgICAgICAgdHJhbnNpdGlvbjogaGVpZ2h0IC4zNHMgY3ViaWMt
YmV6aWVyKC4yMiwgMSwgLjM2LCAxKSAhaW1wb3J0YW50OwogICAgICAgIH0KICAgICAgICAuaXRtOmhv
dmVyOjpiZWZvcmUgeyBoZWlnaHQ6IDMzLjMzMyUgIWltcG9ydGFudDsgfQogICAgICAgIC5pdG06OmFm
dGVyIHsKICAgICAgICAgICAgY29udGVudDogIiIgIWltcG9ydGFudDsKICAgICAgICAgICAgcG9zaXRp
b246IGFic29sdXRlICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIGxlZnQ6IDAgIWltcG9ydGFudDsgcmln
aHQ6IDAgIWltcG9ydGFudDsgYm90dG9tOiAwICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIGhlaWdodDog
MnB4ICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIHBvaW50ZXItZXZlbnRzOiBub25lICFpbXBvcnRhbnQ7
CiAgICAgICAgICAgIHotaW5kZXg6IDEgIWltcG9ydGFudDsKICAgICAgICAgICAgYmFja2dyb3VuZDog
cmdiYSg5MSwgMTE1LCAyMzIsIC45MikgIWltcG9ydGFudDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1
czogMXB4ICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIHRyYW5zZm9ybTogc2NhbGVYKDApICFpbXBvcnRh
bnQ7CiAgICAgICAgICAgIHRyYW5zZm9ybS1vcmlnaW46IGNlbnRlciAhaW1wb3J0YW50OwogICAgICAg
ICAgICB0cmFuc2l0aW9uOiB0cmFuc2Zvcm0gLjNzIGN1YmljLWJlemllciguMjIsIDEsIC4zNiwgMSkg
IWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgLml0bTpob3Zlcjo6YWZ0ZXIgewogICAgICAgICAg
ICB0cmFuc2Zvcm06IHNjYWxlWCgxKSAhaW1wb3J0YW50OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiBy
Z2JhKDkxLCAxMTUsIDIzMiwgLjk1KSAhaW1wb3J0YW50OwogICAgICAgIH0KICAgICAgICAuaXRtID4g
KiB7IHBvc2l0aW9uOiByZWxhdGl2ZTsgei1pbmRleDogMjsgfQogICAgICAgICAgICAvKiB3aGl0ZS1w
YW5lbC1ib3JkZXI6IG91dGVyIGVkZ2UgbGluZSByZW1vdmVkICovCiAgICAgICAgI2FwcCB7CiAgICAg
ICAgICAgIGJvcmRlcjogbm9uZSAhaW1wb3J0YW50OwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiAw
ICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIGJveC1zaXppbmc6IGJvcmRlci1ib3ggIWltcG9ydGFudDsK
ICAgICAgICAgICAgb3ZlcmZsb3c6IGhpZGRlbiAhaW1wb3J0YW50OwogICAgICAgIH0KICAgICAgICAu
aXRtLCAubWcsIC5tZy1yb3csIC5tZXJnZS1ncm91cCB7CiAgICAgICAgICAgIGJvcmRlcjogMXB4IHNv
bGlkICNmZmZmZmYgIWltcG9ydGFudDsKICAgICAgICB9CiAgICA8L3N0eWxlPgo8L2hlYWQ+Cjxib2R5
Pgo8ZGl2IGlkPSJhcHAiIGNsYXNzPSJib290LWxvYWRpbmciPgogICAgPGRpdiBpZD0iaGRyIj4KICAg
ICAgICA8ZGl2IGlkPSJoZWFydCI+CiAgICAgICAgICAgIDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBm
aWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiCiAgICAgICAg
ICAgICAgICAgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIj4KICAg
ICAgICAgICAgICAgIDxyZWN0IHg9IjkiIHk9IjIiIHdpZHRoPSI2IiBoZWlnaHQ9IjQiIHJ4PSIxIi8+
CiAgICAgICAgICAgICAgICA8cGF0aCBkPSJNMTYgNGgyYTIgMiAwIDAgMSAyIDJ2MTRhMiAyIDAgMCAx
LTIgMkg2YTIgMiAwIDAgMS0yLTJWNmEyIDIgMCAwIDEgMi0yaDIiLz4KICAgICAgICAgICAgICAgIDxw
YXRoIGQ9Ik05IDEyaDZNOSAxNmg0Ii8+CiAgICAgICAgICAgIDwvc3ZnPgogICAgICAgIDwvZGl2Pgog
ICAgICAgIDxkaXYgaWQ9Imhkci1ncm93Ij48L2Rpdj4KICAgICAgICA8YnV0dG9uIGlkPSJidG4tbG9j
YXRlIiB0eXBlPSJidXR0b24iIHRpdGxlPSLlrprkvY3liLDkuIrmrKHkvb/nlKjnmoTmnaHnm64iIGRp
c2FibGVkPgogICAgICAgICAgICA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ry
b2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMiIKICAgICAgICAgICAgICAgICBzdHJva2Ut
bGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9pbj0icm91bmQiPgogICAgICAgICAgICAgICAgPGNp
cmNsZSBjeD0iMTIiIGN5PSIxMiIgcj0iOCIvPgogICAgICAgICAgICAgICAgPGNpcmNsZSBjeD0iMTIi
IGN5PSIxMiIgcj0iMy41Ii8+CiAgICAgICAgICAgIDwvc3ZnPgogICAgICAgIDwvYnV0dG9uPgogICAg
ICAgIDxkaXYgaWQ9InNlYXJjaC13cmFwIj4KICAgICAgICAgICAgPGJ1dHRvbiBpZD0iYnRuLXNlYXJj
aCIgdHlwZT0iYnV0dG9uIiB0aXRsZT0i5pCc57SiIj4KICAgICAgICAgICAgICAgIDxzdmcgdmlld0Jv
eD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRo
PSIyIgogICAgICAgICAgICAgICAgICAgICBzdHJva2UtbGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5l
am9pbj0icm91bmQiPgogICAgICAgICAgICAgICAgICAgIDxjaXJjbGUgY3g9IjExIiBjeT0iMTEiIHI9
IjciLz4KICAgICAgICAgICAgICAgICAgICA8cGF0aCBkPSJNMjAgMjBsLTMuNS0zLjUiLz4KICAgICAg
ICAgICAgICAgIDwvc3ZnPgogICAgICAgICAgICA8L2J1dHRvbj4KICAgICAgICAgICAgPGRpdiBpZD0i
c2VhcmNoLWJveCI+CiAgICAgICAgICAgICAgICA8YnV0dG9uIGlkPSJidG4tdG9kYXkiIHR5cGU9ImJ1
dHRvbiI+5b2T5aSpPC9idXR0b24+CiAgICAgICAgICAgICAgICA8aW5wdXQgaWQ9InNlYXJjaCIgdHlw
ZT0idGV4dCIgcGxhY2Vob2xkZXI9IuaQnOe0ouKApiBhfGJ8YyDpobvlkIzml7bljIXlkKsiIGF1dG9j
b21wbGV0ZT0ib2ZmIiBzcGVsbGNoZWNrPSJmYWxzZSI+CiAgICAgICAgICAgICAgICA8YnV0dG9uIGlk
PSJzZWFyY2gtY2xyIiB0eXBlPSJidXR0b24iPuKclTwvYnV0dG9uPgogICAgICAgICAgICA8L2Rpdj4K
ICAgICAgICA8L2Rpdj4KICAgICAgICA8YnV0dG9uIGlkPSJidG4tcGluIiB0eXBlPSJidXR0b24iIHRp
dGxlPSLpkonlnKjlsY/luZXkuIoiPgogICAgICAgICAgICA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIg
ZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMiIKICAgICAgICAg
ICAgICAgICBzdHJva2UtbGluZWpvaW49InJvdW5kIiBzdHJva2UtbGluZWNhcD0icm91bmQiPgogICAg
ICAgICAgICAgICAgPGxpbmUgeDE9IjEyIiB5MT0iMTciIHgyPSIxMiIgeTI9IjIyIi8+CiAgICAgICAg
ICAgICAgICA8cGF0aCBkPSJNNSAxN2gxNHYtMS43NmEyIDIgMCAwIDAtMS4xMS0xLjc5bC0xLjc4LS45
QTIgMiAwIDAgMSAxNSAxMC43NlY2aDFhMiAyIDAgMCAwIDAtNEg4YTIgMiAwIDAgMCAwIDRoMXY0Ljc2
YTIgMiAwIDAgMS0xLjExIDEuNzlsLTEuNzguOUEyIDIgMCAwIDAgNSAxNS4yNFoiLz4KICAgICAgICAg
ICAgPC9zdmc+CiAgICAgICAgPC9idXR0b24+CiAgICA8L2Rpdj4KCiAgICA8ZGl2IGlkPSJ0YWJzIj4K
ICAgICAgICA8ZGl2IGlkPSJ0YWItaW5rIiBhcmlhLWhpZGRlbj0idHJ1ZSI+PC9kaXY+CiAgICAgICAg
PGRpdiBjbGFzcz0idGFiIG9uIiBkYXRhLXRhYj0iYWxsIj7lhajpg6g8L2Rpdj4KICAgICAgICA8ZGl2
IGNsYXNzPSJ0YWIiIGRhdGEtdGFiPSJ0ZXh0Ij7mlofmnKw8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNz
PSJ0YWIiIGRhdGEtdGFiPSJpbWFnZSI+5Zu+5YOPPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0idGFi
IiBkYXRhLXRhYj0iZmlsZSI+5paH5Lu2PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0idGFiIiBkYXRh
LXRhYj0icGlubmVkIj7mlLbol48gPHNwYW4gY2xhc3M9ImJhZGdlIiBpZD0icGluLWNudCIgc3R5bGU9
ImRpc3BsYXk6bm9uZSI+MDwvc3Bhbj48L2Rpdj4KICAgICAgICA8ZGl2IGlkPSJ0YWItYWN0aW9ucyI+
CiAgICAgICAgICAgIDxidXR0b24gaWQ9Im11bHRpLWNudCIgdHlwZT0iYnV0dG9uIiB0aXRsZT0i5Y+W
5raI5aSa6YCJIj4wPC9idXR0b24+CiAgICAgICAgICAgIDxzcGFuIGlkPSJiYXItdHh0Ij4wPC9zcGFu
PgogICAgICAgICAgICA8YnV0dG9uIGlkPSJidG4tY2xyIiB0eXBlPSJidXR0b24iIHRpdGxlPSLmuIXn
qbrljoblj7IiPgogICAgICAgICAgICAgICAgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5v
bmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIiCiAgICAgICAgICAgICAgICAg
ICAgIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI+CiAgICAgICAg
ICAgICAgICAgICAgPHBvbHlsaW5lIHBvaW50cz0iMyA2IDUgNiAyMSA2Ii8+CiAgICAgICAgICAgICAg
ICAgICAgPHBhdGggZD0iTTE5IDZsLTEgMTRhMiAyIDAgMCAxLTIgMkg4YTIgMiAwIDAgMS0yLTJMNSA2
Ii8+CiAgICAgICAgICAgICAgICAgICAgPHBhdGggZD0iTTEwIDExdjZNMTQgMTF2Nk05IDZWNGg2djIi
Lz4KICAgICAgICAgICAgICAgIDwvc3ZnPgogICAgICAgICAgICA8L2J1dHRvbj4KICAgICAgICA8L2Rp
dj4KICAgIDwvZGl2PgoKICAgIDxkaXYgaWQ9Imxpc3QiPgogICAgICAgIDxkaXYgaWQ9InNrZWwiIGNs
YXNzPSJvbiIgYXJpYS1oaWRkZW49InRydWUiPgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJzay1yb3ci
PjxkaXYgY2xhc3M9InNrLWljbyI+PC9kaXY+PGRpdiBjbGFzcz0ic2stYm9keSI+PGRpdiBjbGFzcz0i
c2stbGluZSBtaWQiPjwvZGl2PjxkaXYgY2xhc3M9InNrLWxpbmUgc2hvcnQiPjwvZGl2PjwvZGl2Pjwv
ZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJzay1yb3ciPjxkaXYgY2xhc3M9InNrLWljbyI+PC9k
aXY+PGRpdiBjbGFzcz0ic2stYm9keSI+PGRpdiBjbGFzcz0ic2stbGluZSI+PC9kaXY+PGRpdiBjbGFz
cz0ic2stbGluZSBtaWQiPjwvZGl2PjwvZGl2PjwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJz
ay1yb3ciPjxkaXYgY2xhc3M9InNrLWljbyI+PC9kaXY+PGRpdiBjbGFzcz0ic2stYm9keSI+PGRpdiBj
bGFzcz0ic2stbGluZSBtaWQiPjwvZGl2PjxkaXYgY2xhc3M9InNrLWxpbmUgc2hvcnQiPjwvZGl2Pjwv
ZGl2PjwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJzay1yb3ciPjxkaXYgY2xhc3M9InNrLWlj
byI+PC9kaXY+PGRpdiBjbGFzcz0ic2stYm9keSI+PGRpdiBjbGFzcz0ic2stbGluZSI+PC9kaXY+PGRp
diBjbGFzcz0ic2stbGluZSBtaWQiPjwvZGl2PjwvZGl2PjwvZGl2PgogICAgICAgICAgICA8ZGl2IGNs
YXNzPSJzay1yb3ciPjxkaXYgY2xhc3M9InNrLWljbyI+PC9kaXY+PGRpdiBjbGFzcz0ic2stYm9keSI+
PGRpdiBjbGFzcz0ic2stbGluZSBtaWQiPjwvZGl2PjxkaXYgY2xhc3M9InNrLWxpbmUgc2hvcnQiPjwv
ZGl2PjwvZGl2PjwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJzay1yb3ciPjxkaXYgY2xhc3M9
InNrLWljbyI+PC9kaXY+PGRpdiBjbGFzcz0ic2stYm9keSI+PGRpdiBjbGFzcz0ic2stbGluZSI+PC9k
aXY+PGRpdiBjbGFzcz0ic2stbGluZSBzaG9ydCI+PC9kaXY+PC9kaXY+PC9kaXY+CiAgICAgICAgPC9k
aXY+CiAgICAgICAgPGRpdiBpZD0iZW1wdHkiPgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJlLXR4dCIg
aWQ9ImVtcHR5LXR4dCI+5pqC5peg6K6w5b2V77yM5aSN5Yi25ZCO6Ieq5Yqo5Ye6546wPC9kaXY+CiAg
ICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KICAgIDxidXR0b24gaWQ9ImJ0bi10b3AiIHR5cGU9ImJ1dHRv
biIgdGl0bGU9IuWbnuWIsOmhtumDqCIgYXJpYS1sYWJlbD0i5Zue5Yiw6aG26YOoIj4KICAgICAgICA8
c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0
cm9rZS13aWR0aD0iMi4yIgogICAgICAgICAgICAgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2Ut
bGluZWpvaW49InJvdW5kIj4KICAgICAgICAgICAgPHBhdGggZD0iTTEyIDE5VjUiLz4KICAgICAgICAg
ICAgPHBhdGggZD0iTTUgMTJsNy03IDcgNyIvPgogICAgICAgIDwvc3ZnPgogICAgPC9idXR0b24+Cjwv
ZGl2PgoKPGRpdiBpZD0iY3R4Ij4KICAgIDxkaXYgY2xhc3M9ImMtaXRlbSIgaWQ9ImMtY29weSI+PHNw
YW4gY2xhc3M9ImMtaWNvIj7ijpg8L3NwYW4+5aSN5Yi2PC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjLWl0
ZW0iIGlkPSJjLXBhc3RlIj48c3BhbiBjbGFzcz0iYy1pY28iPuKPjjwvc3Bhbj7nspjotLQ8L2Rpdj4K
ICAgIDxkaXYgY2xhc3M9ImMtc2VwIj48L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImMtaXRlbSIgaWQ9ImMt
cGluIj48c3BhbiBjbGFzcz0iYy1pY28iPuKYhTwvc3Bhbj7mlLbol488L2Rpdj4KICAgIDxkaXYgY2xh
c3M9ImMtaXRlbSIgaWQ9ImMtdGl0bGUiIHN0eWxlPSJkaXNwbGF5Om5vbmUiPjxzcGFuIGNsYXNzPSJj
LWljbyI+4pyOPC9zcGFuPuiuvue9ruagh+mimDwvZGl2PgogICAgPGRpdiBjbGFzcz0iYy1pdGVtIiBp
ZD0iYy1tZXJnZSIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+PHNwYW4gY2xhc3M9ImMtaWNvIj7ip4k8L3Nw
YW4+5ZCI5bm2PC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0iIGlkPSJjLXVubWVyZ2UiIHN0eWxl
PSJkaXNwbGF5Om5vbmUiPjxzcGFuIGNsYXNzPSJjLWljbyI+4oeEPC9zcGFuPuWPlua2iOWQiOW5tjwv
ZGl2PgogICAgPGRpdiBjbGFzcz0iYy1pdGVtIiBpZD0iYy10b3AiPjxzcGFuIGNsYXNzPSJjLWljbyI+
4oaRPC9zcGFuPuenu+WIsOmhtumDqDwvZGl2PgogICAgPGRpdiBjbGFzcz0iYy1pdGVtIiBpZD0iYy1j
bGVhci1wYXN0ZWQiIHN0eWxlPSJkaXNwbGF5Om5vbmUiPjxzcGFuIGNsYXNzPSJjLWljbyI+4pyTPC9z
cGFuPua4hemZpOeKtuaAgTwvZGl2PgogICAgPGRpdiBjbGFzcz0iYy1zZXAiPjwvZGl2PgogICAgPGRp
diBjbGFzcz0iYy1pdGVtIGRhbmdlciIgaWQ9ImMtZGVsIj48c3BhbiBjbGFzcz0iYy1pY28iPuKclTwv
c3Bhbj7liKDpmaQ8L2Rpdj4KPC9kaXY+Cgo8ZGl2IGlkPSJjbHItZGxnIj4KICAgIDxkaXYgY2xhc3M9
ImNsci1ib3giIHJvbGU9ImRpYWxvZyIgYXJpYS1tb2RhbD0idHJ1ZSI+CiAgICAgICAgPGRpdiBjbGFz
cz0iY2xyLXRpdGxlIiBpZD0iY2xyLXRpdGxlIj7noa7orqTmuIXnqbrvvJ88L2Rpdj4KICAgICAgICA8
ZGl2IGNsYXNzPSJjbHItZGVzYyIgaWQ9ImNsci1kZXNjIj7pu5jorqTku4XmuIXnqbrlvZPlpKnlhoXl
rrnjgII8L2Rpdj4KICAgICAgICA8bGFiZWwgY2xhc3M9ImNsci1jaGVjayIgZm9yPSJjbHItYWxsIj4K
ICAgICAgICAgICAgPGlucHV0IHR5cGU9ImNoZWNrYm94IiBpZD0iY2xyLWFsbCI+CiAgICAgICAgICAg
IDxzcGFuPua4heepuuaJgOaciTwvc3Bhbj4KICAgICAgICA8L2xhYmVsPgogICAgICAgIDxkaXYgY2xh
c3M9ImNsci1idG5zIj4KICAgICAgICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGlkPSJjbHItY2Fu
Y2VsIj7lj5bmtog8L2J1dHRvbj4KICAgICAgICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGlkPSJj
bHItb2siPua4heepujwvYnV0dG9uPgogICAgICAgIDwvZGl2PgogICAgPC9kaXY+CjwvZGl2PgoKPGRp
diBpZD0idGl0bGUtZGxnIj4KICAgIDxkaXYgY2xhc3M9InRpdGxlLWJveCIgcm9sZT0iZGlhbG9nIiBh
cmlhLW1vZGFsPSJ0cnVlIj4KICAgICAgICA8ZGl2IGNsYXNzPSJjbHItdGl0bGUiPuiuvue9ruagh+mi
mDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImNsci1kZXNjIj7moIfpopjlj6/ooqvmkJzntKLmib7l
iLDvvIzku4XnlKjkuo7mlLbol4/mlbTnkIbjgII8L2Rpdj4KICAgICAgICA8aW5wdXQgaWQ9InRpdGxl
LWlucHV0IiB0eXBlPSJ0ZXh0IiBtYXhsZW5ndGg9IjgwIiBwbGFjZWhvbGRlcj0i57uZ6L+Z5p2h5pS2
6JeP6LW35Liq5ZCN5a2X4oCmIiBhdXRvY29tcGxldGU9Im9mZiIgc3BlbGxjaGVjaz0iZmFsc2UiPgog
ICAgICAgIDxkaXYgY2xhc3M9ImNsci1idG5zIj4KICAgICAgICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0
b24iIGlkPSJ0aXRsZS1jYW5jZWwiPuWPlua2iDwvYnV0dG9uPgogICAgICAgICAgICA8YnV0dG9uIHR5
cGU9ImJ1dHRvbiIgaWQ9InRpdGxlLW9rIj7kv53lrZg8L2J1dHRvbj4KICAgICAgICA8L2Rpdj4KICAg
IDwvZGl2Pgo8L2Rpdj4KPGRpdiBpZD0icGF0aC10aXAiIGFyaWEtaGlkZGVuPSJ0cnVlIj48L2Rpdj4K
CjxzY3JpcHQ+Ci8qIHNrZWwtZmFpbHNhZmU6IG9ubHkgaWYgbWFpbiBVSSBzY3JpcHQgbmV2ZXIgYm9v
dGVkICovCihmdW5jdGlvbigpewogIHNldFRpbWVvdXQoKCkgPT4gewogICAgdHJ5IHsKICAgICAgaWYg
KHdpbmRvdy5fX3VpQm9vdGVkKSByZXR1cm47CiAgICAgIHZhciBhcHAgPSBkb2N1bWVudC5nZXRFbGVt
ZW50QnlJZCgnYXBwJyk7CiAgICAgIGlmIChhcHApIGFwcC5jbGFzc0xpc3QucmVtb3ZlKCdib290LWxv
YWRpbmcnKTsKICAgICAgdmFyIHMgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2tlbCcpOwogICAg
ICBpZiAocykgcy5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICB2YXIgZSA9IGRvY3VtZW50Lmdl
dEVsZW1lbnRCeUlkKCdlbXB0eScpOwogICAgICBpZiAoZSAmJiAhZG9jdW1lbnQucXVlcnlTZWxlY3Rv
cignI2xpc3QgLml0bScpKSBlLmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAgICB9IGNhdGNoIChlcnIpIHt9
CiAgfSwgMzAwMCk7Cn0pKCk7Cjwvc2NyaXB0Pgo8c2NyaXB0PgogICAgbGV0IGFsbENsaXBzID0gW10s
IGN1clRhYiA9ICdhbGwnLCBxdWVyeSA9ICcnLCBjdHhDbGlwID0gbnVsbCwgc2VsZWN0ZWRJZCA9IDAs
IHBpbm5lZFVJID0gZmFsc2U7CiAgICBjb25zdCBUQUJfT1JERVIgPSBbJ2FsbCcsICd0ZXh0JywgJ2lt
YWdlJywgJ2ZpbGUnLCAncGlubmVkJ107CiAgICBjb25zdCB2aWV3TWVtID0gbmV3IE1hcCgpOwogICAg
ZnVuY3Rpb24gdmlld01lbUtleSh0YWIsIHEsIHRvZGF5KSB7CiAgICAgICAgcmV0dXJuIFN0cmluZyh0
YWIgfHwgJ2FsbCcpICsgJ1x0JyArIFN0cmluZyhxIHx8ICcnKSArICdcdCcgKyAodG9kYXkgPyAnMScg
OiAnMCcpOwogICAgfQogICAgbGV0IHRhYlN3aXRjaEFuaW1EaXIgPSAwOwogICAgbGV0IG11bHRpSWRz
ID0gW107CiAgICBsZXQgdG9kYXlPbmx5ID0gZmFsc2U7CiAgICBsZXQgZGlza1RvdGFsID0gMDsKICAg
IGxldCBsb2FkaW5nTW9yZSA9IGZhbHNlOwogICAgbGV0IGJvb3RMb2FkaW5nID0gdHJ1ZTsKICAgIHdp
bmRvdy5fX2RhdGFSZWFkeSA9IGZhbHNlOwogICAgd2luZG93Ll9fdWlCb290ZWQgPSB0cnVlOwogICAg
Ly8gT3BlbiBwYW5lbCB3aXRob3V0IHBhc3Rpbmcg4oaSIGFsd2F5cyBsYW5kIG9uIGZpcnN0IGl0ZW0g
KGFmdGVyIGRhdGEgYXJyaXZlcykKICAgIGxldCBzZWxlY3RGaXJzdE9uU2hvdyA9IGZhbHNlOwogICAg
bGV0IGxhc3RQYXN0ZUlkID0gMDsKICAgIGxldCBsYXN0UGFzdGVUYWIgPSAnYWxsJzsKICAgIGxldCBs
b2NhdGVBY3RpdmUgPSBmYWxzZTsKICAgIHRyeSB7IGxhc3RQYXN0ZUlkID0gK2xvY2FsU3RvcmFnZS5n
ZXRJdGVtKCdjbGlwTGFzdFBhc3RlSWQnKSB8fCAwOyB9IGNhdGNoIHt9CiAgICB0cnkgewogICAgICAg
IGNvbnN0IHQgPSBsb2NhbFN0b3JhZ2UuZ2V0SXRlbSgnY2xpcExhc3RQYXN0ZVRhYicpIHx8ICdhbGwn
OwogICAgICAgIGxhc3RQYXN0ZVRhYiA9IFsnYWxsJywndGV4dCcsJ2ltYWdlJywnZmlsZScsJ3Bpbm5l
ZCddLmluY2x1ZGVzKHQpID8gdCA6ICdhbGwnOwogICAgfSBjYXRjaCB7fQogICAgLy8gU2FtZS1vcmln
aW4gdW5kZXIgY2xpcHVpLmxvY2FsIChBUFBfSE9TVCDihpIgQ0xJUF9WMV9ESVIpLiBDcm9zcy1ob3N0
IGNsaXBzLnN0b3JlIGlzIHVucmVsaWFibGUuCiAgICBjb25zdCBTVE9SRV9CQVNFID0gKGxvY2F0aW9u
Lm9yaWdpbiAmJiBsb2NhdGlvbi5vcmlnaW4uaW5kZXhPZignaHR0cHM6Ly8nKSA9PT0gMCkKICAgICAg
ICA/IChsb2NhdGlvbi5vcmlnaW4ucmVwbGFjZSgvXC8kLywgJycpICsgJy9jbGlwc19zdG9yZS8nKQog
ICAgICAgIDogJ2h0dHBzOi8vY2xpcHVpLmxvY2FsL2NsaXBzX3N0b3JlLyc7CiAgICBmdW5jdGlvbiBt
ZXRhQ2VudGVySHRtbChleHBhbmRJbm5lcikgewogICAgICAgIGlmIChleHBhbmRJbm5lciA9PSBudWxs
IHx8IGV4cGFuZElubmVyID09PSBmYWxzZSkKICAgICAgICAgICAgcmV0dXJuIGA8c3BhbiBjbGFzcz0i
aS1tZXRhLWNlbnRlciI+PC9zcGFuPmA7CiAgICAgICAgcmV0dXJuIGA8c3BhbiBjbGFzcz0iaS1tZXRh
LWNlbnRlciI+PGJ1dHRvbiBjbGFzcz0iaS1leHBhbmQtYnRuJHtleHBhbmRJbm5lci5vbiA/ICcgb24n
IDogJyd9IiB0eXBlPSJidXR0b24iIHRpdGxlPSLlsZXlvIAv5pS26LW3Ij4ke2V4cGFuZElubmVyLmh0
bWx9PC9idXR0b24+PC9zcGFuPmA7CiAgICB9CgogICAgZnVuY3Rpb24gcmVtZW1iZXJMYXN0UGFzdGUo
aWQpIHsKICAgICAgICBsYXN0UGFzdGVJZCA9ICtpZCB8fCAwOwogICAgICAgIGxhc3RQYXN0ZVRhYiA9
IGN1clRhYiB8fCAnYWxsJzsKICAgICAgICB0cnkgewogICAgICAgICAgICBsb2NhbFN0b3JhZ2Uuc2V0
SXRlbSgnY2xpcExhc3RQYXN0ZUlkJywgU3RyaW5nKGxhc3RQYXN0ZUlkKSk7CiAgICAgICAgICAgIGxv
Y2FsU3RvcmFnZS5zZXRJdGVtKCdjbGlwTGFzdFBhc3RlVGFiJywgbGFzdFBhc3RlVGFiKTsKICAgICAg
ICB9IGNhdGNoIHt9CiAgICAgICAgdXBkYXRlTG9jYXRlQnRuKCk7CiAgICB9CiAgICBmdW5jdGlvbiB1
cGRhdGVMb2NhdGVCdG4oKSB7CiAgICAgICAgY29uc3QgYnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ2J0bi1sb2NhdGUnKTsKICAgICAgICBpZiAoIWJ0bikgcmV0dXJuOwogICAgICAgIGJ0bi5kaXNh
YmxlZCA9ICFsYXN0UGFzdGVJZDsKICAgICAgICBidG4uY2xhc3NMaXN0LnRvZ2dsZSgnaGFzLXRhcmdl
dCcsICEhbGFzdFBhc3RlSWQpOwogICAgICAgIGJ0bi5jbGFzc0xpc3QudG9nZ2xlKCdvbicsIGxvY2F0
ZUFjdGl2ZSAmJiAhIWxhc3RQYXN0ZUlkKTsKICAgICAgICBidG4udGl0bGUgPSAhbGFzdFBhc3RlSWQK
ICAgICAgICAgICAgPyAn5pqC5peg5LiK5qyh5L2/55So5L2N572uJwogICAgICAgICAgICA6IChsb2Nh
dGVBY3RpdmUgPyAn5Y+W5raI5a6a5L2N77yM5Zue5Yiw56ys5LiA5p2hJyA6ICflrprkvY3liLDkuIrm
rKHkvb/nlKjnmoTmnaHnm64nKTsKICAgIH0KICAgIGZ1bmN0aW9uIHNlbGVjdEZpcnN0SXRlbSgpIHsK
ICAgICAgICBsb2NhdGVBY3RpdmUgPSBmYWxzZTsKICAgICAgICB3aW5kb3cuX19wZW5kaW5nSnVtcElk
ID0gMDsKICAgICAgICB3aW5kb3cuX19qdW1wTG9hZFRyaWVzID0gMDsKICAgICAgICBzZWxlY3RGaXJz
dE9uU2hvdyA9IGZhbHNlOwogICAgICAgIGNvbnN0IHZpcyA9IHZpc2libGVMaXN0KCk7CiAgICAgICAg
aWYgKCF2aXMubGVuZ3RoKSB7CiAgICAgICAgICAgIHNlbGVjdGVkSWQgPSAwOwogICAgICAgICAgICBz
eW5jSXRlbUhpZ2hsaWdodCgpOwogICAgICAgICAgICB1cGRhdGVMb2NhdGVCdG4oKTsKICAgICAgICAg
ICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBzZWxlY3RlZElkID0gdmlzWzBdLmlkOwogICAgICAg
IHJhbmdlQW5jaG9ySWQgPSBzZWxlY3RlZElkOwogICAgICAgIHJhbmdlQW5jaG9yQ2xpY2tlZCA9IGZh
bHNlOwogICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSAwOwogICAgICAgIHN5bmNJdGVtSGlnaGxpZ2h0
KCk7CiAgICAgICAgY29uc3QgZWwgPSBsaXN0RWwucXVlcnlTZWxlY3RvcignLml0bVtkYXRhLWlkPSIn
ICsgc2VsZWN0ZWRJZCArICciXScpOwogICAgICAgIGlmIChlbCkgZWwuc2Nyb2xsSW50b1ZpZXcoeyBi
bG9jazogJ25lYXJlc3QnIH0pOwogICAgICAgIHVwZGF0ZUxvY2F0ZUJ0bigpOwogICAgfQogICAgZnVu
Y3Rpb24ganVtcFRvTGFzdFBhc3RlKCkgewogICAgICAgIGlmICghbGFzdFBhc3RlSWQpIHJldHVybjsK
ICAgICAgICAvLyBBbHJlYWR5IGxvY2F0ZWQgb24gbGFzdCBwYXN0ZSDihpIgY2FuY2VsIGFuZCBzZWxl
Y3QgZmlyc3QKICAgICAgICBpZiAobG9jYXRlQWN0aXZlICYmICtzZWxlY3RlZElkID09PSArbGFzdFBh
c3RlSWQpIHsKICAgICAgICAgICAgc2VsZWN0Rmlyc3RJdGVtKCk7CiAgICAgICAgICAgIHJldHVybjsK
ICAgICAgICB9CiAgICAgICAgbG9jYXRlQWN0aXZlID0gdHJ1ZTsKICAgICAgICBzZWxlY3RGaXJzdE9u
U2hvdyA9IGZhbHNlOwogICAgICAgIC8vIENsZWFyIGZpbHRlcnMgc28gdGhlIGl0ZW0gaXMgZmluZGFi
bGUgb24gdGhlIHRhYiB3aGVyZSBpdCB3YXMgdXNlZAogICAgICAgIHF1ZXJ5ID0gJyc7CiAgICAgICAg
dG9kYXlPbmx5ID0gZmFsc2U7CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgY29uc3Qgc3JjaCA9IGRv
Y3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gnKTsKICAgICAgICAgICAgY29uc3Qgc2NsciA9IGRv
Y3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gtY2xyJyk7CiAgICAgICAgICAgIGNvbnN0IHdyYXAg
PSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLXdyYXAnKTsKICAgICAgICAgICAgY29uc3Qg
YnRuVG9kYXkgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLXRvZGF5Jyk7CiAgICAgICAgICAg
IGlmIChzcmNoKSB7IHNyY2gudmFsdWUgPSAnJzsgc3JjaC5jbGFzc0xpc3QucmVtb3ZlKCdoYXMtdmFs
Jyk7IH0KICAgICAgICAgICAgaWYgKHNjbHIpIHNjbHIuc3R5bGUuZGlzcGxheSA9ICdub25lJzsKICAg
ICAgICAgICAgaWYgKHdyYXApIHdyYXAuY2xhc3NMaXN0LnJlbW92ZSgnb3BlbicpOwogICAgICAgICAg
ICBpZiAoYnRuVG9kYXkpIGJ0blRvZGF5LmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgfSBj
YXRjaCB7fQogICAgICAgIGNvbnN0IHRhYiA9IFsnYWxsJywndGV4dCcsJ2ltYWdlJywnZmlsZScsJ3Bp
bm5lZCddLmluY2x1ZGVzKGxhc3RQYXN0ZVRhYikKICAgICAgICAgICAgPyBsYXN0UGFzdGVUYWIgOiAn
YWxsJzsKICAgICAgICBjb25zdCBwcmV2VGFiID0gY3VyVGFiOwogICAgICAgIGN1clRhYiA9IHRhYjsK
ICAgICAgICBsb2FkaW5nTW9yZSA9IGZhbHNlOwogICAgICAgIG1hcmtUYWIodGFiKTsKICAgICAgICBj
bGVhck11bHRpKCk7CiAgICAgICAgc2VsZWN0ZWRJZCA9IGxhc3RQYXN0ZUlkOwogICAgICAgIHdpbmRv
dy5fX3BlbmRpbmdKdW1wSWQgPSBsYXN0UGFzdGVJZDsKICAgICAgICB3aW5kb3cuX19qdW1wTG9hZFRy
aWVzID0gMDsKICAgICAgICB3aW5kb3cuX19qdW1wRmVsbEJhY2sgPSBmYWxzZTsKICAgICAgICB1cGRh
dGVMb2NhdGVCdG4oKTsKICAgICAgICByZXF1ZXN0VmlldygpOwogICAgfQoKICAgIGZ1bmN0aW9uIHJl
cXVlc3RWaWV3KCkgewogICAgICAgIGNvbnN0IHRhYiA9IGN1clRhYiwgcSA9IHF1ZXJ5LCB0b2RheSA9
IHRvZGF5T25seSA/ICcxJyA6ICcwJzsKICAgICAgICBpZiAod2luZG93Ll9fdmlld1JhZikgY2FuY2Vs
QW5pbWF0aW9uRnJhbWUod2luZG93Ll9fdmlld1JhZik7CiAgICAgICAgd2luZG93Ll9fdmlld1JhZiA9
IHJlcXVlc3RBbmltYXRpb25GcmFtZSgoKSA9PiB7CiAgICAgICAgICAgIHdpbmRvdy5fX3ZpZXdSYWYg
PSAwOwogICAgICAgICAgICBzZXRUaW1lb3V0KCgpID0+IGFoaygnc2V0VmlldycsIHRhYiwgcSwgdG9k
YXkpLCAwKTsKICAgICAgICB9KTsKICAgIH0KICAgIGZ1bmN0aW9uIHJlcXVlc3RNb3JlKCkgewogICAg
ICAgIGlmIChsb2FkaW5nTW9yZSkgcmV0dXJuOwogICAgICAgIGlmIChkaXNrVG90YWwgPiAwICYmIGFs
bENsaXBzLmxlbmd0aCA+PSBkaXNrVG90YWwpIHJldHVybjsKICAgICAgICBsb2FkaW5nTW9yZSA9IHRy
dWU7CiAgICAgICAgc2V0VGltZW91dCgoKSA9PiBhaGsoJ2xvYWRNb3JlJyksIDApOwogICAgfQogICAg
Y29uc3QgRU1QVFlfTVNHID0gewogICAgICAgIGFsbDogICAgJ+aaguaXoOiusOW9le+8jOWkjeWItuWQ
juiHquWKqOWHuueOsCcsCiAgICAgICAgdGV4dDogICAn5pqC5peg5paH5pysJywKICAgICAgICBpbWFn
ZTogICfmmoLml6Dlm77lg48nLAogICAgICAgIGZpbGU6ICAgJ+aaguaXoOaWh+S7ticsCiAgICAgICAg
cGlubmVkOiAn5pqC5peg5pS26JePJwogICAgfTsKCiAgICBmdW5jdGlvbiBhaGtJbnZva2UobWV0aG9k
LCBhcmdzKSB7CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgY29uc3QgaG9zdCA9IGNocm9tZS53ZWJ2
aWV3Lmhvc3RPYmplY3RzLnN5bmMuYWhrOwogICAgICAgICAgICBpZiAoIWhvc3QpIHJldHVybjsKICAg
ICAgICAgICAgbGV0IGNhbGxlZCA9IGZhbHNlOwogICAgICAgICAgICBpZiAodHlwZW9mIGhvc3QuY2Fs
bCA9PT0gJ2Z1bmN0aW9uJykgewogICAgICAgICAgICAgICAgdHJ5IHsgaG9zdC5jYWxsKG1ldGhvZCwg
Li4uYXJncyk7IGNhbGxlZCA9IHRydWU7IH0gY2F0Y2gge30KICAgICAgICAgICAgfQogICAgICAgICAg
ICBpZiAoIWNhbGxlZCAmJiB0eXBlb2YgaG9zdFttZXRob2RdID09PSAnZnVuY3Rpb24nKSB7CiAgICAg
ICAgICAgICAgICB0cnkgeyBob3N0W21ldGhvZF0oLi4uYXJncyk7IGNhbGxlZCA9IHRydWU7IH0gY2F0
Y2gge30KICAgICAgICAgICAgICAgIGlmICghY2FsbGVkKSB7CiAgICAgICAgICAgICAgICAgICAgdHJ5
IHsgaG9zdFttZXRob2RdKC4uLmFyZ3MpOyBjYWxsZWQgPSB0cnVlOyB9IGNhdGNoIHt9CiAgICAgICAg
ICAgICAgICB9CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKCFjYWxsZWQgJiYgaG9zdFttZXRo
b2RdICE9IG51bGwgJiYgdHlwZW9mIGhvc3RbbWV0aG9kXSAhPT0gJ2Z1bmN0aW9uJykgewogICAgICAg
ICAgICAgICAgdHJ5IHsgdm9pZCBob3N0W21ldGhvZF07IH0gY2F0Y2gge30KICAgICAgICAgICAgfQog
ICAgICAgIH0gY2F0Y2ggKGUpIHsgY29uc29sZS53YXJuKCdhaGsuJyArIG1ldGhvZCwgZSk7IH0KICAg
IH0KICAgIGZ1bmN0aW9uIGFoayhtZXRob2QsIC4uLmFyZ3MpIHsKICAgICAgICBhaGtJbnZva2UobWV0
aG9kLCBhcmdzKTsKICAgIH0KICAgIGZ1bmN0aW9uIGFoa1JldChtZXRob2QsIC4uLmFyZ3MpIHsKICAg
ICAgICB0cnkgewogICAgICAgICAgICBjb25zdCBob3N0ID0gY2hyb21lLndlYnZpZXcuaG9zdE9iamVj
dHMuc3luYy5haGs7CiAgICAgICAgICAgIGlmICghaG9zdCkgcmV0dXJuIG51bGw7CiAgICAgICAgICAg
IGxldCByZXQgPSBudWxsOwogICAgICAgICAgICBpZiAodHlwZW9mIGhvc3QuY2FsbCA9PT0gJ2Z1bmN0
aW9uJykgewogICAgICAgICAgICAgICAgdHJ5IHsgcmV0ID0gaG9zdC5jYWxsKG1ldGhvZCwgLi4uYXJn
cyk7IH0gY2F0Y2gge30KICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAocmV0ID09IG51bGwgJiYg
dHlwZW9mIGhvc3RbbWV0aG9kXSA9PT0gJ2Z1bmN0aW9uJykgewogICAgICAgICAgICAgICAgdHJ5IHsg
cmV0ID0gaG9zdFttZXRob2RdKC4uLmFyZ3MpOyB9IGNhdGNoIHt9CiAgICAgICAgICAgICAgICBpZiAo
cmV0ID09IG51bGwpIHsKICAgICAgICAgICAgICAgICAgICB0cnkgeyByZXQgPSBob3N0W21ldGhvZF0o
Li4uYXJncyk7IH0gY2F0Y2gge30KICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgfQogICAgICAg
ICAgICBpZiAocmV0ID09IG51bGwgJiYgaG9zdFttZXRob2RdICE9IG51bGwgJiYgdHlwZW9mIGhvc3Rb
bWV0aG9kXSAhPT0gJ2Z1bmN0aW9uJykKICAgICAgICAgICAgICAgIHJldCA9IGhvc3RbbWV0aG9kXTsK
ICAgICAgICAgICAgaWYgKHJldCA9PSBudWxsKSByZXR1cm4gbnVsbDsKICAgICAgICAgICAgaWYgKHR5
cGVvZiByZXQgPT09ICdzdHJpbmcnIHx8IHR5cGVvZiByZXQgPT09ICdudW1iZXInIHx8IHR5cGVvZiBy
ZXQgPT09ICdib29sZWFuJykKICAgICAgICAgICAgICAgIHJldHVybiByZXQ7CiAgICAgICAgICAgIHRy
eSB7IHJldHVybiBTdHJpbmcocmV0KTsgfSBjYXRjaCB7IHJldHVybiByZXQ7IH0KICAgICAgICB9IGNh
dGNoIChlKSB7IGNvbnNvbGUud2FybignYWhrUmV0LicgKyBtZXRob2QsIGUpOyB9CiAgICAgICAgcmV0
dXJuIG51bGw7CiAgICB9CgogICAgLy8gRWFybHkgQUhLIF9fc2V0VGh1bWIgY2FuIGFycml2ZSBiZWZv
cmUgRE9NIG5vZGVzIGV4aXN0IOKAlCBrZWVwIHVudGlsIGJpbmQKICAgIGNvbnN0IHRodW1iQ2FjaGUg
PSBuZXcgTWFwKCk7CgogICAgLyoqIFByZWZlciBkYXRhLVVSTCAoQUhLKSwgdGhlbiB2aXJ0dWFsLWhv
c3QgZmlsZSBVUkwgKi8KICAgIGZ1bmN0aW9uIGJpbmRTdG9yZVRodW1iKGltZywgZmlsZSwgaWQsIGZh
bGxiYWNrKSB7CiAgICAgICAgaW1nLmRhdGFzZXQudGh1bWJJZCA9IFN0cmluZyhpZCk7CiAgICAgICAg
aW1nLmFsdCA9ICcnOwogICAgICAgIGNvbnN0IGZhaWxUaW1lciA9IHNldFRpbWVvdXQoKCkgPT4gewog
ICAgICAgICAgICBpZiAoIWltZy5zcmMgfHwgaW1nLm5hdHVyYWxXaWR0aCA8IDEpCiAgICAgICAgICAg
ICAgICBpbWcuYWx0ID0gJ+aXoOazleWKoOi9vSc7CiAgICAgICAgfSwgMTAwMDApOwogICAgICAgIGlt
Zy5fZmFpbFRpbWVyID0gZmFpbFRpbWVyOwogICAgICAgIGNvbnN0IHByZXZMb2FkID0gaW1nLm9ubG9h
ZDsKICAgICAgICBpbWcub25sb2FkID0gZSA9PiB7CiAgICAgICAgICAgIGNsZWFyVGltZW91dChmYWls
VGltZXIpOwogICAgICAgICAgICBpbWcuYWx0ID0gJyc7CiAgICAgICAgICAgIGlmICh0eXBlb2YgcHJl
dkxvYWQgPT09ICdmdW5jdGlvbicpIHByZXZMb2FkLmNhbGwoaW1nLCBlKTsKICAgICAgICB9OwogICAg
ICAgIGltZy5vbmVycm9yID0gKCkgPT4gewogICAgICAgICAgICBpZiAoZmlsZSAmJiAhaW1nLmRhdGFz
ZXQucmV0cmllZCkgewogICAgICAgICAgICAgICAgaW1nLmRhdGFzZXQucmV0cmllZCA9ICcxJzsKICAg
ICAgICAgICAgICAgIGltZy5zcmMgPSBTVE9SRV9CQVNFICsgU3RyaW5nKGZpbGUpLnNwbGl0KCcvJyku
cG9wKCk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaW1n
Lm9uZXJyb3IgPSBudWxsOwogICAgICAgIH07CiAgICAgICAgY29uc3QgY2FjaGVkID0gdGh1bWJDYWNo
ZS5nZXQoU3RyaW5nKGlkKSk7CiAgICAgICAgY29uc3QgZGF0YVVybCA9IChmYWxsYmFjayAmJiBTdHJp
bmcoZmFsbGJhY2spLnN0YXJ0c1dpdGgoJ2RhdGE6JykpCiAgICAgICAgICAgID8gU3RyaW5nKGZhbGxi
YWNrKQogICAgICAgICAgICA6IChjYWNoZWQgJiYgU3RyaW5nKGNhY2hlZCkuc3RhcnRzV2l0aCgnZGF0
YTonKSA/IFN0cmluZyhjYWNoZWQpIDogJycpOwogICAgICAgIGlmIChkYXRhVXJsKSB7CiAgICAgICAg
ICAgIGltZy5zcmMgPSBkYXRhVXJsOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAg
IGlmIChmaWxlKSB7CiAgICAgICAgICAgIGNvbnN0IGJhcmUgPSBTdHJpbmcoZmlsZSkuc3BsaXQoJy8n
KS5wb3AoKTsKICAgICAgICAgICAgaW1nLnNyYyA9IFNUT1JFX0JBU0UgKyBiYXJlOwogICAgICAgIH0K
ICAgIH0KCiAgICB3aW5kb3cuX19zZXRUaHVtYiA9IChpZCwgdXJsKSA9PiB7CiAgICAgICAgaWYgKCF1
cmwpIHJldHVybjsKICAgICAgICBjb25zdCBrZXkgPSBTdHJpbmcoaWQpOwogICAgICAgIHRodW1iQ2Fj
aGUuc2V0KGtleSwgdXJsKTsKICAgICAgICBsZXQgaGl0ID0gMDsKICAgICAgICBkb2N1bWVudC5xdWVy
eVNlbGVjdG9yQWxsKCcuaXRtW2RhdGEtaWQ9IicgKyBrZXkgKyAnIl0gaW1nLmktdGh1bWInKS5mb3JF
YWNoKGltZyA9PiB7CiAgICAgICAgICAgIGlmIChpbWcuX2ZhaWxUaW1lcikgdHJ5IHsgY2xlYXJUaW1l
b3V0KGltZy5fZmFpbFRpbWVyKTsgfSBjYXRjaCB7fQogICAgICAgICAgICBpbWcub25lcnJvciA9IG51
bGw7CiAgICAgICAgICAgIGltZy5hbHQgPSAnJzsKICAgICAgICAgICAgaW1nLnNyYyA9IHVybDsKICAg
ICAgICAgICAgaGl0Kys7CiAgICAgICAgfSk7CiAgICAgICAgLy8gQWxzbyBtYXRjaCBudW1lcmljIGlk
IGF0dHJpYnV0ZSBxdWlya3MKICAgICAgICBpZiAoIWhpdCkgewogICAgICAgICAgICBkb2N1bWVudC5x
dWVyeVNlbGVjdG9yQWxsKCdpbWcuaS10aHVtYltkYXRhLXRodW1iLWlkPSInICsga2V5ICsgJyJdJyku
Zm9yRWFjaChpbWcgPT4gewogICAgICAgICAgICAgICAgaWYgKGltZy5fZmFpbFRpbWVyKSB0cnkgeyBj
bGVhclRpbWVvdXQoaW1nLl9mYWlsVGltZXIpOyB9IGNhdGNoIHt9CiAgICAgICAgICAgICAgICBpbWcu
b25lcnJvciA9IG51bGw7CiAgICAgICAgICAgICAgICBpbWcuYWx0ID0gJyc7CiAgICAgICAgICAgICAg
ICBpbWcuc3JjID0gdXJsOwogICAgICAgICAgICB9KTsKICAgICAgICB9CiAgICB9OwoKICAgIGZ1bmN0
aW9uIGlzRHJhZ0V4Y2x1ZGUodCkgewogICAgICAgIHJldHVybiAhIXQuY2xvc2VzdCgnI3NlYXJjaC13
cmFwLCAjYnRuLXNlYXJjaCwgI2J0bi1sb2NhdGUsICNidG4tdG9kYXksICNidG4tcGluLCAjYnRuLWNs
ciwgI211bHRpLWNudCwgLnRhYiwgLml0bSwgI3RhYi1hY3Rpb25zLCAjY3R4LCAjY2xyLWRsZywgI3Bh
dGgtdGlwLCBidXR0b24sIGlucHV0LCBhJyk7CiAgICB9CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJ
ZCgnYXBwJykuYWRkRXZlbnRMaXN0ZW5lcignbW91c2Vkb3duJywgZSA9PiB7CiAgICAgICAgaWYgKGUu
YnV0dG9uICE9PSAwKSByZXR1cm47CiAgICAgICAgaWYgKGlzRHJhZ0V4Y2x1ZGUoZS50YXJnZXQpKSBy
ZXR1cm47CiAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgIGFoaygnc3RhcnREcmFnJyk7
CiAgICB9LCB0cnVlKTsKCiAgICBjb25zdCBpc1VybCAgPSBzID0+IC9eaHR0cHM/OlwvXC8vaS50ZXN0
KChzIHx8ICcnKS50cmltKCkpOwoKICAgIGZ1bmN0aW9uIGFnbyhkYXRlU3RyKSB7CiAgICAgICAgdHJ5
IHsKICAgICAgICAgICAgY29uc3QgZCA9IG5ldyBEYXRlKFN0cmluZyhkYXRlU3RyKS5yZXBsYWNlKCcg
JywgJ1QnKSk7CiAgICAgICAgICAgIGNvbnN0IHMgPSAoRGF0ZS5ub3coKSAtIGQpIC8gMTAwMCB8IDA7
CiAgICAgICAgICAgIGlmIChzIDwgNjApIHJldHVybiAn5Yia5YiaJzsKICAgICAgICAgICAgaWYgKHMg
PCAzNjAwKSByZXR1cm4gKHMgLyA2MCB8IDApICsgJyDliIbpkp/liY0nOwogICAgICAgICAgICBpZiAo
cyA8IDg2NDAwKSByZXR1cm4gKHMgLyAzNjAwIHwgMCkgKyAnIOWwj+aXtuWJjSc7CiAgICAgICAgICAg
IHJldHVybiAocyAvIDg2NDAwIHwgMCkgKyAnIOWkqeWJjSc7CiAgICAgICAgfSBjYXRjaCB7IHJldHVy
biBkYXRlU3RyOyB9CiAgICB9CgogICAgZnVuY3Rpb24gbm9ybVR5cGUodCkgewogICAgICAgIHQgPSBT
dHJpbmcodCB8fCAnJykudG9Mb3dlckNhc2UoKTsKICAgICAgICBpZiAodCA9PT0gJ2ltYWdlJyB8fCB0
ID09PSAnaW1nJyB8fCB0ID09PSAnYml0bWFwJykgcmV0dXJuICdpbWFnZSc7CiAgICAgICAgaWYgKHQg
PT09ICdmaWxlJyAgfHwgdCA9PT0gJ2ZpbGVzJykgcmV0dXJuICdmaWxlJzsKICAgICAgICByZXR1cm4g
J3RleHQnOwogICAgfQogICAgZnVuY3Rpb24gaXNQaW5uZWQoYykgewogICAgICAgIHJldHVybiBjLnBp
bm5lZCA9PT0gdHJ1ZSB8fCBjLnBpbm5lZCA9PT0gMSB8fCBjLnBpbm5lZCA9PT0gJ3RydWUnIHx8IGMu
cGlubmVkID09PSAnMSc7CiAgICB9CiAgICBmdW5jdGlvbiBpc1Bhc3RlZChjKSB7CiAgICAgICAgcmV0
dXJuIGMucGFzdGVkID09PSB0cnVlIHx8IGMucGFzdGVkID09PSAxIHx8IGMucGFzdGVkID09PSAndHJ1
ZScgfHwgYy5wYXN0ZWQgPT09ICcxJzsKICAgIH0KCiAgICBmdW5jdGlvbiBpc01hcmtkb3duKHRleHQp
IHsKICAgICAgICBpZiAoIXRleHQgfHwgdGV4dC5sZW5ndGggPCA0KSByZXR1cm4gZmFsc2U7CiAgICAg
ICAgcmV0dXJuIC8oPzpefFxuKSN7MSw2fSB8XlstKitdIHxcKlwqW14qXG5dK1wqXCp8X19bXl9cbl0r
X198KD86Xnxcbik+IHxgYGB8YFteYFxuXStgfFxbW15cXV0rXF1cKFteKV0rXCl8XHwuK1x8LitcfC9t
LnRlc3QodGV4dCk7CiAgICB9CiAgICBmdW5jdGlvbiBjbGlwVXNlc01JY29uKGMpIHsKICAgICAgICBp
ZiAoIWMpIHJldHVybiBmYWxzZTsKICAgICAgICBpZiAoYy5pc01kID09PSB0cnVlIHx8IGMuaXNNZCA9
PT0gMSB8fCBjLmlzTWQgPT09ICd0cnVlJyB8fCBjLmlzTWQgPT09ICcxJykgcmV0dXJuIHRydWU7CiAg
ICAgICAgaWYgKGMuaXNSaWNoID09PSB0cnVlIHx8IGMuaXNSaWNoID09PSAxIHx8IGMuaXNSaWNoID09
PSAndHJ1ZScgfHwgYy5pc1JpY2ggPT09ICcxJykgcmV0dXJuIHRydWU7CiAgICAgICAgY29uc3QgdCA9
IFN0cmluZyhjLnR5cGUgfHwgJycpLnRvTG93ZXJDYXNlKCk7CiAgICAgICAgaWYgKHQgJiYgdCAhPT0g
J3RleHQnICYmIHQgIT09ICdsaW5rJykgcmV0dXJuIGZhbHNlOwogICAgICAgIHJldHVybiBpc01hcmtk
b3duKGMuZGF0YSB8fCBjLnByZXZpZXcgfHwgJycpOwogICAgfQogICAgZnVuY3Rpb24gZXNjQXR0cihz
KSB7CiAgICAgICAgcmV0dXJuIFN0cmluZyhzIHx8ICcnKQogICAgICAgICAgICAucmVwbGFjZSgvJi9n
LCAnJmFtcDsnKQogICAgICAgICAgICAucmVwbGFjZSgvIi9nLCAnJnF1b3Q7JykKICAgICAgICAgICAg
LnJlcGxhY2UoLzwvZywgJyZsdDsnKQogICAgICAgICAgICAucmVwbGFjZSgvPi9nLCAnJmd0OycpOwog
ICAgfQoKICAgIGZ1bmN0aW9uIHRvZGF5UHJlZml4KCkgewogICAgICAgIGNvbnN0IGQgPSBuZXcgRGF0
ZSgpOwogICAgICAgIGNvbnN0IHAgPSBuID0+IFN0cmluZyhuKS5wYWRTdGFydCgyLCAnMCcpOwogICAg
ICAgIHJldHVybiBkLmdldEZ1bGxZZWFyKCkgKyAnLScgKyBwKGQuZ2V0TW9udGgoKSArIDEpICsgJy0n
ICsgcChkLmdldERhdGUoKSk7CiAgICB9CiAgICBmdW5jdGlvbiBpc1RvZGF5Q2xpcChjKSB7CiAgICAg
ICAgcmV0dXJuIFN0cmluZyhjLnRpbWUgfHwgJycpLnN0YXJ0c1dpdGgodG9kYXlQcmVmaXgoKSk7CiAg
ICB9CgogICAgZnVuY3Rpb24gY2xpcEhheShjKSB7CiAgICAgICAgcmV0dXJuIFN0cmluZyhjLnByZXZp
ZXcgfHwgJycpICsgJyAnICsgU3RyaW5nKGMuZGF0YSB8fCAnJykgKyAnICcKICAgICAgICAgICAgKyBT
dHJpbmcoYy5saW5rVGl0bGUgfHwgJycpICsgJyAnICsgU3RyaW5nKGMuZmF2VGl0bGUgfHwgJycpOwog
ICAgfQogICAgZnVuY3Rpb24gZmlsdGVyKGNsaXBzLCB0YWIsIHEpIHsKICAgICAgICAvLyDkuLvmnLrl
t7Lov4fmu6Tml7bku43lgZrliY3nq6/lhZzlupXvvJrpgb/lhY3nq57mgIHmjqjmnaXmnKrlkb3kuK3o
oYwKICAgICAgICBjb25zdCB0ZXJtcyA9IHF1ZXJ5VGVybXMocSk7CiAgICAgICAgaWYgKCF0ZXJtcy5s
ZW5ndGgpIHJldHVybiBjbGlwczsKICAgICAgICBjb25zdCB0ZXJtTCA9IHRlcm1zLm1hcCh0ID0+IHQu
dG9Mb3dlckNhc2UoKSk7CiAgICAgICAgcmV0dXJuIGNsaXBzLmZpbHRlcihjID0+IHsKICAgICAgICAg
ICAgY29uc3QgdHlwZSA9IFN0cmluZyhjLnR5cGUgfHwgJycpLnRvTG93ZXJDYXNlKCk7CiAgICAgICAg
ICAgIGxldCBoYXkgPSAnJzsKICAgICAgICAgICAgaWYgKHR5cGUgPT09ICdpbWFnZScpCiAgICAgICAg
ICAgICAgICBoYXkgPSBTdHJpbmcoYy5mYXZUaXRsZSB8fCAnJyk7CiAgICAgICAgICAgIGVsc2UKICAg
ICAgICAgICAgICAgIGhheSA9IGNsaXBIYXkoYyk7CiAgICAgICAgICAgIGNvbnN0IGxvd2VyID0gaGF5
LnRvTG93ZXJDYXNlKCk7CiAgICAgICAgICAgIHJldHVybiB0ZXJtTC5ldmVyeSh0ID0+IGxvd2VyLmlu
Y2x1ZGVzKHQpKTsKICAgICAgICB9KTsKICAgIH0KCiAgICBmdW5jdGlvbiBtYXJrUGFzdGVkTG9jYWwo
aWRzKSB7CiAgICAgICAgY29uc3QgbGlzdCA9IEFycmF5LmlzQXJyYXkoaWRzKSA/IGlkcyA6IFtpZHNd
OwogICAgICAgIGlmIChsaXN0Lmxlbmd0aCkKICAgICAgICAgICAgcmVtZW1iZXJMYXN0UGFzdGUobGlz
dFtsaXN0Lmxlbmd0aCAtIDFdKTsKICAgICAgICBjb25zdCBiYWRnZUh0bWwgPSBgPHN2ZyB2aWV3Qm94
PSIwIDAgMTYgMTYiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9
IjIuNCIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIj48cG9seWxp
bmUgcG9pbnRzPSIzLjUgOC41IDYuNSAxMS41IDEyLjUgNC41Ii8+PC9zdmc+YDsKICAgICAgICBsaXN0
LmZvckVhY2goaWQgPT4gewogICAgICAgICAgICBjb25zdCBjID0gYWxsQ2xpcHMuZmluZCh4ID0+ICt4
LmlkID09PSAraWQpOwogICAgICAgICAgICBpZiAoYykgYy5wYXN0ZWQgPSB0cnVlOwogICAgICAgICAg
ICBjb25zdCBpY28gPSBsaXN0RWwucXVlcnlTZWxlY3RvcignLml0bVtkYXRhLWlkPSInICsgaWQgKyAn
Il0gLmktaWNvJyk7CiAgICAgICAgICAgIGlmIChpY28gJiYgIWljby5xdWVyeVNlbGVjdG9yKCcuaS11
c2VkJykpIHsKICAgICAgICAgICAgICAgIGNvbnN0IGJhZGdlID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVu
dCgnc3BhbicpOwogICAgICAgICAgICAgICAgYmFkZ2UuY2xhc3NOYW1lID0gJ2ktdXNlZCc7CiAgICAg
ICAgICAgICAgICBiYWRnZS50aXRsZSA9ICflt7LnspjotLQnOwogICAgICAgICAgICAgICAgYmFkZ2Uu
aW5uZXJIVE1MID0gYmFkZ2VIdG1sOwogICAgICAgICAgICAgICAgaWNvLmFwcGVuZENoaWxkKGJhZGdl
KTsKICAgICAgICAgICAgfQogICAgICAgIH0pOwogICAgfQoKICAgIGNvbnN0IGxpc3RFbCAgPSBkb2N1
bWVudC5nZXRFbGVtZW50QnlJZCgnbGlzdCcpOwogICAgY29uc3QgZW1wdHlFbCA9IGRvY3VtZW50Lmdl
dEVsZW1lbnRCeUlkKCdlbXB0eScpOwogICAgY29uc3Qgc2tlbEVsICA9IGRvY3VtZW50LmdldEVsZW1l
bnRCeUlkKCdza2VsJyk7CiAgICBjb25zdCBidG5Ub3AgID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQo
J2J0bi10b3AnKTsKICAgIGZ1bmN0aW9uIHNldEJvb3RMb2FkaW5nKG9uKSB7CiAgICAgICAgYm9vdExv
YWRpbmcgPSAhIW9uOwogICAgICAgIGlmIChib290TG9hZGluZykgd2luZG93Ll9fc2tlbFNpbmNlID0g
RGF0ZS5ub3coKTsKICAgICAgICBpZiAoc2tlbEVsKSBza2VsRWwuY2xhc3NMaXN0LnRvZ2dsZSgnb24n
LCBib290TG9hZGluZyk7CiAgICAgICAgaWYgKGJvb3RMb2FkaW5nICYmIGVtcHR5RWwpIGVtcHR5RWwu
Y2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICBjb25zdCBhcHAgPSBkb2N1bWVudC5nZXRFbGVt
ZW50QnlJZCgnYXBwJyk7CiAgICAgICAgaWYgKGFwcCkgYXBwLmNsYXNzTGlzdC50b2dnbGUoJ2Jvb3Qt
bG9hZGluZycsIGJvb3RMb2FkaW5nKTsKICAgIH0KICAgIHdpbmRvdy5zZXRCb290TG9hZGluZyA9IHNl
dEJvb3RMb2FkaW5nOwogICAgd2luZG93LmZvcmNlRW5kQm9vdExvYWRpbmcgPSBmdW5jdGlvbigpIHsK
ICAgICAgICBzZXRCb290TG9hZGluZyhmYWxzZSk7CiAgICAgICAgdHJ5IHsgcmVuZGVyKCk7IH0gY2F0
Y2ggKGUpIHt9CiAgICB9OwogICAgLy8gU2FmZXR5OiBuZXZlciBsZWF2ZSBza2VsZXRvbiBzdHVjayBp
ZiBob3N0IHB1c2ggaXMgZHJvcHBlZCB3aGlsZSBzdGlsbCBsb2FkaW5nCiAgICBzZXRUaW1lb3V0KCgp
ID0+IHsKICAgICAgICBpZiAod2luZG93Ll9fZGF0YVJlYWR5IHx8ICFib290TG9hZGluZykgcmV0dXJu
OwogICAgICAgIHNldEJvb3RMb2FkaW5nKGZhbHNlKTsKICAgICAgICB0cnkgeyByZW5kZXIoKTsgfSBj
YXRjaCB7fQogICAgfSwgODAwMCk7CgogICAgZnVuY3Rpb24gdXBkYXRlVG9wQnRuKCkgewogICAgICAg
IGlmICghYnRuVG9wIHx8ICFsaXN0RWwpIHJldHVybjsKICAgICAgICBidG5Ub3AuY2xhc3NMaXN0LnRv
Z2dsZSgnb24nLCBsaXN0RWwuc2Nyb2xsVG9wID4gNDgpOwogICAgfQogICAgZnVuY3Rpb24gb25MaXN0
U2Nyb2xsKCkgewogICAgICAgIGhpZGVQYXRoVGlwKCk7CiAgICAgICAgdXBkYXRlVG9wQnRuKCk7CiAg
ICAgICAgaWYgKGxvYWRpbmdNb3JlKSByZXR1cm47CiAgICAgICAgLy8g6Led56a75bqV6YOoIDI0MHB4
IOinpuWPkeWKoOi9veabtOWkmu+8jOavlOWOn+adpSAxMDBweCDmm7TnqLPvvJvlv6vpgJ/mu5rliqjm
l7bkuI3kvJoKICAgICAgICAvLyDov57nu63op6blj5EgcmVxdWVzdE1vcmXvvIjlt7LnlKggbG9hZGlu
Z01vcmUg6Ziy6YeN5YWl77yM5L2G5q2k5aSE5LuN6YG/5YWN5oqW5Yqo77yJ44CCCiAgICAgICAgaWYg
KGxpc3RFbC5zY3JvbGxUb3AgKyBsaXN0RWwuY2xpZW50SGVpZ2h0ID49IGxpc3RFbC5zY3JvbGxIZWln
aHQgLSAyNDApCiAgICAgICAgICAgIHJlcXVlc3RNb3JlKCk7CiAgICB9CiAgICBsaXN0RWwuYWRkRXZl
bnRMaXN0ZW5lcignc2Nyb2xsJywgb25MaXN0U2Nyb2xsLCB7IHBhc3NpdmU6IHRydWUgfSk7CiAgICBi
dG5Ub3AuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICBlLnN0b3BQcm9wYWdh
dGlvbigpOwogICAgICAgIGxpc3RFbC5zY3JvbGxUbyh7IHRvcDogMCwgYmVoYXZpb3I6ICdzbW9vdGgn
IH0pOwogICAgfSk7CgogICAgZnVuY3Rpb24gdmlzaWJsZUxpc3QoKSB7IHJldHVybiBmaWx0ZXIoYWxs
Q2xpcHMsIGN1clRhYiwgcXVlcnkpOyB9CiAgICBmdW5jdGlvbiBlc2NIdG1sKHMpIHsKICAgICAgICBy
ZXR1cm4gU3RyaW5nKHMgPz8gJycpLnJlcGxhY2UoLyYvZywnJmFtcDsnKS5yZXBsYWNlKC88L2csJyZs
dDsnKS5yZXBsYWNlKC8+L2csJyZndDsnKS5yZXBsYWNlKC8iL2csJyZxdW90OycpOwogICAgfQogICAg
ZnVuY3Rpb24gcXVlcnlUZXJtcyhxKSB7CiAgICAgICAgcmV0dXJuIFN0cmluZyhxIHx8ICcnKS5zcGxp
dCgnfCcpLm1hcCh0ID0+IHQudHJpbSgpKS5maWx0ZXIoQm9vbGVhbik7CiAgICB9CiAgICBmdW5jdGlv
biBobEh0bWwodGV4dCkgewogICAgICAgIGNvbnN0IHRlcm1zID0gcXVlcnlUZXJtcyhxdWVyeSk7CiAg
ICAgICAgY29uc3QgcyA9IFN0cmluZyh0ZXh0ID8/ICcnKTsKICAgICAgICBpZiAoIXRlcm1zLmxlbmd0
aCkgcmV0dXJuIGVzY0h0bWwocyk7CiAgICAgICAgY29uc3QgbG93ZXIgPSBzLnRvTG93ZXJDYXNlKCk7
CiAgICAgICAgY29uc3QgdGVybUwgPSB0ZXJtcy5tYXAodCA9PiB0LnRvTG93ZXJDYXNlKCkpOwogICAg
ICAgIGxldCBvdXQgPSAnJywgaSA9IDA7CiAgICAgICAgd2hpbGUgKGkgPCBzLmxlbmd0aCkgewogICAg
ICAgICAgICBsZXQgYmVzdEogPSAtMSwgYmVzdExlbiA9IDA7CiAgICAgICAgICAgIGZvciAobGV0IHRp
ID0gMDsgdGkgPCB0ZXJtTC5sZW5ndGg7IHRpKyspIHsKICAgICAgICAgICAgICAgIGNvbnN0IHQgPSB0
ZXJtTFt0aV07CiAgICAgICAgICAgICAgICBpZiAoIXQpIGNvbnRpbnVlOwogICAgICAgICAgICAgICAg
Y29uc3QgaiA9IGxvd2VyLmluZGV4T2YodCwgaSk7CiAgICAgICAgICAgICAgICBpZiAoaiA8IDApIGNv
bnRpbnVlOwogICAgICAgICAgICAgICAgaWYgKGJlc3RKIDwgMCB8fCBqIDwgYmVzdEogfHwgKGogPT09
IGJlc3RKICYmIHQubGVuZ3RoID4gYmVzdExlbikpIHsKICAgICAgICAgICAgICAgICAgICBiZXN0SiA9
IGo7IGJlc3RMZW4gPSB0Lmxlbmd0aDsKICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgfQogICAg
ICAgICAgICBpZiAoYmVzdEogPCAwKSB7IG91dCArPSBlc2NIdG1sKHMuc2xpY2UoaSkpOyBicmVhazsg
fQogICAgICAgICAgICBvdXQgKz0gZXNjSHRtbChzLnNsaWNlKGksIGJlc3RKKSk7CiAgICAgICAgICAg
IG91dCArPSAnPG1hcmsgY2xhc3M9InEtaGwiPicgKyBlc2NIdG1sKHMuc2xpY2UoYmVzdEosIGJlc3RK
ICsgYmVzdExlbikpICsgJzwvbWFyaz4nOwogICAgICAgICAgICBpID0gYmVzdEogKyBNYXRoLm1heCgx
LCBiZXN0TGVuKTsKICAgICAgICB9CiAgICAgICAgcmV0dXJuIG91dDsKICAgIH0KICAgIGZ1bmN0aW9u
IHNldEhsVGV4dChlbCwgdGV4dCkgewogICAgICAgIGlmICghZWwpIHJldHVybjsKICAgICAgICBjb25z
dCBxID0gU3RyaW5nKHF1ZXJ5IHx8ICcnKS50cmltKCk7CiAgICAgICAgaWYgKCFxKSB7CiAgICAgICAg
ICAgIGVsLmNsYXNzTGlzdC5yZW1vdmUoJ2hhcy1obCcpOwogICAgICAgICAgICBlbC50ZXh0Q29udGVu
dCA9IHRleHQgPT0gbnVsbCA/ICcnIDogU3RyaW5nKHRleHQpOwogICAgICAgICAgICByZXR1cm47CiAg
ICAgICAgfQogICAgICAgIGVsLmNsYXNzTGlzdC5hZGQoJ2hhcy1obCcpOwogICAgICAgIGVsLmlubmVy
SFRNTCA9IGhsSHRtbCh0ZXh0KTsKICAgIH0KCgogICAgZnVuY3Rpb24gYXBwbHlUYWJTd2l0Y2hBbmlt
KCkgewogICAgICAgIGlmICghdGFiU3dpdGNoQW5pbURpciB8fCAhbGlzdEVsKSByZXR1cm47CiAgICAg
ICAgaWYgKCFsaXN0RWwucXVlcnlTZWxlY3RvcignLml0bSwgI2VtcHR5Lm9uLCAjbGlzdC1tb3JlJykp
CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICBjb25zdCBkaXIgPSB0YWJTd2l0Y2hBbmltRGlyOwog
ICAgICAgIHRhYlN3aXRjaEFuaW1EaXIgPSAwOwogICAgICAgIGxpc3RFbC5jbGFzc0xpc3QucmVtb3Zl
KCd0YWItaW4tbHInLCAndGFiLWluLXJsJyk7CiAgICAgICAgdm9pZCBsaXN0RWwub2Zmc2V0V2lkdGg7
CiAgICAgICAgbGlzdEVsLmNsYXNzTGlzdC5hZGQoZGlyID4gMCA/ICd0YWItaW4tbHInIDogJ3RhYi1p
bi1ybCcpOwogICAgICAgIGNsZWFyVGltZW91dChsaXN0RWwuX3RhYkFuaW1UaW1lcik7CiAgICAgICAg
bGlzdEVsLl90YWJBbmltVGltZXIgPSBzZXRUaW1lb3V0KCgpID0+IHsKICAgICAgICAgICAgbGlzdEVs
LmNsYXNzTGlzdC5yZW1vdmUoJ3RhYi1pbi1scicsICd0YWItaW4tcmwnKTsKICAgICAgICB9LCA0MDAp
OwogICAgfQoKICAgIGZ1bmN0aW9uIHRhYkluZGV4KHRhYikgewogICAgICAgIGNvbnN0IGkgPSBUQUJf
T1JERVIuaW5kZXhPZih0YWIpOwogICAgICAgIHJldHVybiBpID49IDAgPyBpIDogMDsKICAgIH0KCiAg
ICBmdW5jdGlvbiBtb3ZlVGFiSW5rKGluc3RhbnQsIHRhcmdldEVsKSB7CiAgICAgICAgY29uc3QgaW5r
ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RhYi1pbmsnKTsKICAgICAgICBjb25zdCB0YWJzID0g
ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RhYnMnKTsKICAgICAgICBjb25zdCBlbCA9IHRhcmdldEVs
IHx8IGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3IoJyN0YWJzIC50YWIub24nKTsKICAgICAgICBpZiAoIWlu
ayB8fCAhdGFicyB8fCAhZWwpIHJldHVybjsKICAgICAgICBjb25zdCB0ciA9IHRhYnMuZ2V0Qm91bmRp
bmdDbGllbnRSZWN0KCk7CiAgICAgICAgY29uc3QgciA9IGVsLmdldEJvdW5kaW5nQ2xpZW50UmVjdCgp
OwogICAgICAgIGNvbnN0IHggPSByLmxlZnQgLSB0ci5sZWZ0OwogICAgICAgIGNvbnN0IGggPSBNYXRo
Lm1heCgyMCwgTWF0aC5yb3VuZChyLmhlaWdodCkpOwogICAgICAgIGNvbnN0IHkgPSByLnRvcCAtIHRy
LnRvcDsKICAgICAgICBjb25zdCB3ID0gTWF0aC5tYXgoMjQsIHIud2lkdGgpOwogICAgICAgIGNvbnN0
IHBvcyA9ICd0cmFuc2xhdGUzZCgnICsgeCArICdweCwnICsgeSArICdweCwwKSc7CiAgICAgICAgaW5r
LnN0eWxlLnRyYW5zZm9ybU9yaWdpbiA9ICdjZW50ZXIgYm90dG9tJzsKICAgICAgICBpbmsuc3R5bGUu
d2lkdGggPSB3ICsgJ3B4JzsKICAgICAgICBpbmsuc3R5bGUuaGVpZ2h0ID0gaCArICdweCc7CiAgICAg
ICAgaWYgKGluc3RhbnQpIHsKICAgICAgICAgICAgaW5rLnN0eWxlLnRyYW5zaXRpb24gPSAnbm9uZSc7
CiAgICAgICAgICAgIGluay5jbGFzc0xpc3QucmVtb3ZlKCdzcXVhc2gnKTsKICAgICAgICAgICAgaW5r
LnN0eWxlLnRyYW5zZm9ybSA9IHBvcyArICcgc2NhbGVYKDEpJzsKICAgICAgICAgICAgaW5rLm9mZnNl
dEhlaWdodDsKICAgICAgICAgICAgaW5rLnN0eWxlLnRyYW5zaXRpb24gPSAnJzsKICAgICAgICAgICAg
cmV0dXJuOwogICAgICAgIH0KICAgICAgICAvLyBTbmFwIHRvIGhvdmVyZWQgdGFiLCBleHBhbmQgZnJv
bSBib3R0b20tY2VudGVyIOKAlCBubyBzbGlkaW5nIGJldHdlZW4gdGFicwogICAgICAgIGluay5zdHls
ZS50cmFuc2l0aW9uID0gJ25vbmUnOwogICAgICAgIGluay5zdHlsZS50cmFuc2Zvcm0gPSBwb3MgKyAn
IHNjYWxlWCgwLjAwMSknOwogICAgICAgIGluay5vZmZzZXRIZWlnaHQ7CiAgICAgICAgaW5rLnN0eWxl
LnRyYW5zaXRpb24gPSAnJzsKICAgICAgICBpbmsuY2xhc3NMaXN0LmFkZCgnc3F1YXNoJyk7CiAgICAg
ICAgaW5rLnN0eWxlLnRyYW5zZm9ybSA9IHBvcyArICcgc2NhbGVYKDEpJzsKICAgICAgICBjbGVhclRp
bWVvdXQoaW5rLl9zcXVhc2hUaW1lcik7CiAgICAgICAgaW5rLl9zcXVhc2hUaW1lciA9IHNldFRpbWVv
dXQoKCkgPT4gaW5rLmNsYXNzTGlzdC5yZW1vdmUoJ3NxdWFzaCcpLCAzNDApOwogICAgfQogICAgZnVu
Y3Rpb24gbWFya1RhYih0YWIsIGluc3RhbnQpIHsKICAgICAgICBkb2N1bWVudC5xdWVyeVNlbGVjdG9y
QWxsKCcjdGFicyAudGFiJykuZm9yRWFjaChlbCA9PgogICAgICAgICAgICBlbC5jbGFzc0xpc3QudG9n
Z2xlKCdvbicsIGVsLmRhdGFzZXQudGFiID09PSB0YWIpKTsKICAgICAgICBtb3ZlVGFiSW5rKCEhaW5z
dGFudCk7CiAgICB9CiAgICBmdW5jdGlvbiBiaW5kVGFiSW5rSG92ZXIoKSB7CiAgICAgICAgY29uc3Qg
dGFicyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0YWJzJyk7CiAgICAgICAgaWYgKCF0YWJzIHx8
IHRhYnMuX2lua0hvdmVyQm91bmQpIHJldHVybjsKICAgICAgICB0YWJzLl9pbmtIb3ZlckJvdW5kID0g
dHJ1ZTsKICAgICAgICB0YWJzLmFkZEV2ZW50TGlzdGVuZXIoJ3BvaW50ZXJvdmVyJywgZSA9PiB7CiAg
ICAgICAgICAgIGNvbnN0IHRhYiA9IGUudGFyZ2V0LmNsb3Nlc3QoJy50YWInKTsKICAgICAgICAgICAg
aWYgKCF0YWIgfHwgIXRhYnMuY29udGFpbnModGFiKSkgcmV0dXJuOwogICAgICAgICAgICBtb3ZlVGFi
SW5rKGZhbHNlLCB0YWIpOwogICAgICAgIH0pOwogICAgICAgIHRhYnMuYWRkRXZlbnRMaXN0ZW5lcign
cG9pbnRlcmxlYXZlJywgZSA9PiB7CiAgICAgICAgICAgIGlmIChlLnJlbGF0ZWRUYXJnZXQgJiYgdGFi
cy5jb250YWlucyhlLnJlbGF0ZWRUYXJnZXQpKSByZXR1cm47CiAgICAgICAgICAgIG1vdmVUYWJJbmso
ZmFsc2UpOwogICAgICAgIH0pOwogICAgfQpmdW5jdGlvbiBzZXRUYWIodGFiKSB7CiAgICAgICAgaWYg
KHRhYiA9PT0gY3VyVGFiKSByZXR1cm47CiAgICAgICAgY29uc3QgZnJvbSA9IHRhYkluZGV4KGN1clRh
Yik7CiAgICAgICAgY29uc3QgdG8gPSB0YWJJbmRleCh0YWIpOwogICAgICAgIHRhYlN3aXRjaEFuaW1E
aXIgPSB0byA+IGZyb20gPyAxIDogKHRvIDwgZnJvbSA/IC0xIDogMCk7CiAgICAgICAgY3VyVGFiID0g
dGFiOwogICAgICAgIGxvYWRpbmdNb3JlID0gZmFsc2U7CiAgICAgICAgbWFya1RhYih0YWIpOwoKICAg
ICAgICAvLyBLZWVwIHNlYXJjaCAidG9kYXkiIGZpbHRlciBpbiBzeW5jIHdoZW4gc2VhcmNoIGlzIG9w
ZW4KICAgICAgICB0cnkgewogICAgICAgICAgICBjb25zdCB3cmFwID0gZG9jdW1lbnQuZ2V0RWxlbWVu
dEJ5SWQoJ3NlYXJjaC13cmFwJyk7CiAgICAgICAgICAgIGNvbnN0IGJ0blRvZGF5ID0gZG9jdW1lbnQu
Z2V0RWxlbWVudEJ5SWQoJ2J0bi10b2RheScpOwogICAgICAgICAgICBpZiAod3JhcCAmJiB3cmFwLmNs
YXNzTGlzdC5jb250YWlucygnb3BlbicpKSB7CiAgICAgICAgICAgICAgICBjb25zdCB3YW50VG9kYXkg
PSBmYWxzZTsKICAgICAgICAgICAgICAgIGlmICh0b2RheU9ubHkgIT09IHdhbnRUb2RheSkgewogICAg
ICAgICAgICAgICAgICAgIHRvZGF5T25seSA9IHdhbnRUb2RheTsKICAgICAgICAgICAgICAgICAgICBp
ZiAoYnRuVG9kYXkpIGJ0blRvZGF5LmNsYXNzTGlzdC50b2dnbGUoJ29uJywgdG9kYXlPbmx5KTsKICAg
ICAgICAgICAgICAgIH0KICAgICAgICAgICAgfQogICAgICAgIH0gY2F0Y2gge30KCiAgICAgICAgc2Vs
ZWN0ZWRJZCA9IG51bGw7CiAgICAgICAgbXVsdGlJZHMgPSBbXTsKICAgICAgICBsaXN0RWwuc2Nyb2xs
VG9wID0gMDsKICAgICAgICBjb25zdCBoaXQgPSB2aWV3TWVtLmdldCh2aWV3TWVtS2V5KHRhYiwgcXVl
cnksIHRvZGF5T25seSkpOwogICAgICAgIGlmIChoaXQgJiYgQXJyYXkuaXNBcnJheShoaXQuaXRlbXMp
KSB7CiAgICAgICAgICAgIGFsbENsaXBzID0gaGl0Lml0ZW1zLnNsaWNlKCk7CiAgICAgICAgICAgIGRp
c2tUb3RhbCA9IE51bWJlcihoaXQudG90YWwpIHx8IGhpdC5pdGVtcy5sZW5ndGg7CiAgICAgICAgICAg
IHdpbmRvdy5fX3dhaXRpbmdWaWV3ID0gZmFsc2U7CiAgICAgICAgICAgIGlmICh3aW5kb3cuX19wZW5k
aW5nU2tlbFRpbWVyKSB7CiAgICAgICAgICAgICAgICBjbGVhclRpbWVvdXQod2luZG93Ll9fcGVuZGlu
Z1NrZWxUaW1lcik7CiAgICAgICAgICAgICAgICB3aW5kb3cuX19wZW5kaW5nU2tlbFRpbWVyID0gMDsK
ICAgICAgICAgICAgfQogICAgICAgICAgICBzZXRCb290TG9hZGluZyhmYWxzZSk7CiAgICAgICAgfSBl
bHNlIHsKICAgICAgICAgICAgYWxsQ2xpcHMgPSBbXTsKICAgICAgICAgICAgZGlza1RvdGFsID0gMDsK
ICAgICAgICAgICAgd2luZG93Ll9fd2FpdGluZ1ZpZXcgPSB0cnVlOwogICAgICAgICAgICBpZiAod2lu
ZG93Ll9fcGVuZGluZ1NrZWxUaW1lcikgY2xlYXJUaW1lb3V0KHdpbmRvdy5fX3BlbmRpbmdTa2VsVGlt
ZXIpOwogICAgICAgICAgICB3aW5kb3cuX19wZW5kaW5nU2tlbFNpbmNlID0gRGF0ZS5ub3coKTsKICAg
ICAgICAgICAgd2luZG93Ll9fcGVuZGluZ1NrZWxUaW1lciA9IHNldFRpbWVvdXQoKCkgPT4gewogICAg
ICAgICAgICAgICAgd2luZG93Ll9fcGVuZGluZ1NrZWxUaW1lciA9IDA7CiAgICAgICAgICAgICAgICBp
ZiAod2luZG93Ll9fd2FpdGluZ1ZpZXcpIHNldEJvb3RMb2FkaW5nKHRydWUpOwogICAgICAgICAgICB9
LCAxODApOwogICAgICAgIH0KICAgICAgICByZXF1ZXN0VmlldygpOwogICAgICAgIHJlbmRlcigpOwog
ICAgICAgIGFwcGx5VGFiU3dpdGNoQW5pbSgpOwogICAgfQoKICAgIG1vdmVUYWJJbmsodHJ1ZSk7CiAg
ICBiaW5kVGFiSW5rSG92ZXIoKTsKICAgIHRyeSB7IG5ldyBSZXNpemVPYnNlcnZlcigoKSA9PiBtb3Zl
VGFiSW5rKHRydWUpKS5vYnNlcnZlKGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0YWJzJykpOyB9IGNh
dGNoIHt9CiAgICB3aW5kb3cuYWRkRXZlbnRMaXN0ZW5lcigncmVzaXplJywgKCkgPT4gbW92ZVRhYklu
ayh0cnVlKSk7CgogICAgZnVuY3Rpb24gdXBkYXRlTW9yZUZvb3Rlcih0b3RhbCkgewogICAgICAgIGxl
dCBtb3JlRWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbGlzdC1tb3JlJyk7CiAgICAgICAgY29u
c3QgbG9hZGVkID0gYWxsQ2xpcHMubGVuZ3RoOwogICAgICAgIGlmIChsb2FkZWQgPj0gdG90YWwpIHsK
ICAgICAgICAgICAgaWYgKG1vcmVFbCkgbW9yZUVsLnJlbW92ZSgpOwogICAgICAgICAgICByZXR1cm47
CiAgICAgICAgfQogICAgICAgIGlmICghbW9yZUVsKSB7CiAgICAgICAgICAgIG1vcmVFbCA9IGRvY3Vt
ZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBtb3JlRWwuaWQgPSAnbGlzdC1tb3Jl
JzsKICAgICAgICAgICAgbW9yZUVsLmNsYXNzTmFtZSA9ICdsaXN0LW1vcmUnOwogICAgICAgICAgICBs
aXN0RWwuYXBwZW5kQ2hpbGQobW9yZUVsKTsKICAgICAgICB9CiAgICAgICAgbW9yZUVsLnRleHRDb250
ZW50ID0gJ+e7p+e7reS4i+a7keS7juejgeebmOWKoOi9ve+8iCcgKyBsb2FkZWQgKyAnLycgKyB0b3Rh
bCArICfvvIknOwogICAgfQoKICAgIGZ1bmN0aW9uIG5hdkxpc3QoKSB7CiAgICAgICAgY29uc3QgYmxv
Y2tzID0gYnVpbGRQaW5uZWRCbG9ja3ModmlzaWJsZUxpc3QoKSk7CiAgICAgICAgY29uc3Qgb3V0ID0g
W107CiAgICAgICAgZm9yIChjb25zdCBiIG9mIGJsb2NrcykgewogICAgICAgICAgICBpZiAoIWIgfHwg
IWIuaXRlbXMpIGNvbnRpbnVlOwogICAgICAgICAgICBmb3IgKGNvbnN0IGMgb2YgYi5pdGVtcykgb3V0
LnB1c2goYyk7CiAgICAgICAgfQogICAgICAgIHJldHVybiBvdXQ7CiAgICB9CgogICAgZnVuY3Rpb24g
c2VsZWN0QnlJbmRleChpZHgpIHsKICAgICAgICBjb25zdCB2aXMgPSBuYXZMaXN0KCk7CiAgICAgICAg
aWYgKCF2aXMubGVuZ3RoKSByZXR1cm47CiAgICAgICAgaWR4ID0gTWF0aC5tYXgoMCwgTWF0aC5taW4o
dmlzLmxlbmd0aCAtIDEsIGlkeCkpOwogICAgICAgIGlmIChpZHggPj0gdmlzLmxlbmd0aCAtIDEgJiYg
YWxsQ2xpcHMubGVuZ3RoIDwgZGlza1RvdGFsKQogICAgICAgICAgICByZXF1ZXN0TW9yZSgpOwogICAg
ICAgIHNlbGVjdGVkSWQgPSB2aXNbTWF0aC5taW4oaWR4LCB2aXMubGVuZ3RoIC0gMSldLmlkOwogICAg
ICAgIHJhbmdlQW5jaG9ySWQgPSBzZWxlY3RlZElkOwogICAgICAgIHJhbmdlQW5jaG9yQ2xpY2tlZCA9
IGZhbHNlOwogICAgICAgIGlmICgrc2VsZWN0ZWRJZCAhPT0gK2xhc3RQYXN0ZUlkKQogICAgICAgICAg
ICBsb2NhdGVBY3RpdmUgPSBmYWxzZTsKICAgICAgICB1cGRhdGVMb2NhdGVCdG4oKTsKICAgICAgICBz
eW5jSXRlbUhpZ2hsaWdodCgpOwogICAgICAgIGNvbnN0IGVsID0gbGlzdEVsLnF1ZXJ5U2VsZWN0b3Io
Jy5tZy1yb3dbZGF0YS1pZD0iJyArIHNlbGVjdGVkSWQgKyAnIl0nKQogICAgICAgICAgICB8fCBsaXN0
RWwucXVlcnlTZWxlY3RvcignLml0bVtkYXRhLWlkPSInICsgc2VsZWN0ZWRJZCArICciXScpOwogICAg
ICAgIGlmIChlbCkgZWwuc2Nyb2xsSW50b1ZpZXcoeyBibG9jazogJ25lYXJlc3QnIH0pOwogICAgfQoK
ICAgIGZ1bmN0aW9uIHNlbGVjdGVkSW5kZXgoKSB7CiAgICAgICAgcmV0dXJuIG5hdkxpc3QoKS5maW5k
SW5kZXgoYyA9PiBjLmlkID09IHNlbGVjdGVkSWQpOwogICAgfQoKICAgIGZ1bmN0aW9uIHN5bmNJdGVt
SGlnaGxpZ2h0KCkgewogICAgICAgIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5pdG0nKS5mb3JF
YWNoKG4gPT4gewogICAgICAgICAgICBpZiAobi5jbGFzc0xpc3QuY29udGFpbnMoJ2l0LWdyb3VwJykp
IHsKICAgICAgICAgICAgICAgIGNvbnN0IHJvd3MgPSBbLi4ubi5xdWVyeVNlbGVjdG9yQWxsKCcubWct
cm93JyldOwogICAgICAgICAgICAgICAgY29uc3QgaWRzID0gcm93cy5tYXAociA9PiArci5kYXRhc2V0
LmlkKTsKICAgICAgICAgICAgICAgIGNvbnN0IGFueVNlbCA9IGlkcy5pbmNsdWRlcygrc2VsZWN0ZWRJ
ZCkgfHwgaWRzLnNvbWUoaWQgPT4gbXVsdGlJZHMuaW5jbHVkZXMoaWQpKTsKICAgICAgICAgICAgICAg
IG4uY2xhc3NMaXN0LnRvZ2dsZSgnc2VsJywgYW55U2VsKTsKICAgICAgICAgICAgICAgIG4uY2xhc3NM
aXN0LnRvZ2dsZSgnbXVsdGknLCBpZHMuc29tZShpZCA9PiBtdWx0aUlkcy5pbmNsdWRlcyhpZCkpKTsK
ICAgICAgICAgICAgICAgIHJvd3MuZm9yRWFjaChyID0+IHsKICAgICAgICAgICAgICAgICAgICBjb25z
dCBpZCA9ICtyLmRhdGFzZXQuaWQ7CiAgICAgICAgICAgICAgICAgICAgY29uc3QgaW5NdWx0aSA9IG11
bHRpSWRzLmluY2x1ZGVzKGlkKTsKICAgICAgICAgICAgICAgICAgICByLmNsYXNzTGlzdC50b2dnbGUo
J3NlbCcsIGlkID09IHNlbGVjdGVkSWQgfHwgaW5NdWx0aSk7CiAgICAgICAgICAgICAgICAgICAgci5j
bGFzc0xpc3QudG9nZ2xlKCdtdWx0aScsIGluTXVsdGkpOwogICAgICAgICAgICAgICAgfSk7CiAgICAg
ICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgY29uc3QgaWQgPSArbi5k
YXRhc2V0LmlkOwogICAgICAgICAgICBjb25zdCBpbk11bHRpID0gbXVsdGlJZHMuaW5jbHVkZXMoaWQp
OwogICAgICAgICAgICBuLmNsYXNzTGlzdC50b2dnbGUoJ3NlbCcsIGlkID09IHNlbGVjdGVkSWQgfHwg
aW5NdWx0aSk7CiAgICAgICAgICAgIG4uY2xhc3NMaXN0LnRvZ2dsZSgnbXVsdGknLCBpbk11bHRpKTsK
ICAgICAgICB9KTsKICAgIH0KICAgIGZ1bmN0aW9uIHVwZGF0ZU11bHRpQmFkZ2UoKSB7CiAgICAgICAg
Y29uc3QgZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbXVsdGktY250Jyk7CiAgICAgICAgaWYg
KG11bHRpSWRzLmxlbmd0aCA+IDApIHsKICAgICAgICAgICAgZWwudGV4dENvbnRlbnQgPSBTdHJpbmco
bXVsdGlJZHMubGVuZ3RoKTsKICAgICAgICAgICAgZWwuY2xhc3NMaXN0LmFkZCgnb24nKTsKICAgICAg
ICB9IGVsc2UgewogICAgICAgICAgICBlbC5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgIH0K
ICAgICAgICBzeW5jSXRlbUhpZ2hsaWdodCgpOwogICAgfQoKICAgIGZ1bmN0aW9uIGNsZWFyTXVsdGko
cmVzdG9yZVRvQW5jaG9yKSB7CiAgICAgICAgY29uc3QgYmFja0lkID0gK3JhbmdlQW5jaG9ySWQgfHwg
MDsKICAgICAgICBtdWx0aUlkcyA9IFtdOwogICAgICAgIGlmIChyZXN0b3JlVG9BbmNob3IgJiYgYmFj
a0lkKQogICAgICAgICAgICBzZWxlY3RlZElkID0gYmFja0lkOwogICAgICAgIHJhbmdlQW5jaG9ySWQg
PSBzZWxlY3RlZElkIHx8IDA7CiAgICAgICAgcmFuZ2VBbmNob3JDbGlja2VkID0gZmFsc2U7CiAgICAg
ICAgdXBkYXRlTXVsdGlCYWRnZSgpOwogICAgICAgIGlmIChyZXN0b3JlVG9BbmNob3IgJiYgc2VsZWN0
ZWRJZCkgewogICAgICAgICAgICBjb25zdCBlbCA9IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcubWctcm93
W2RhdGEtaWQ9IicgKyBzZWxlY3RlZElkICsgJyJdJykKICAgICAgICAgICAgICAgIHx8IGxpc3RFbC5x
dWVyeVNlbGVjdG9yKCcuaXRtW2RhdGEtaWQ9IicgKyBzZWxlY3RlZElkICsgJyJdJyk7CiAgICAgICAg
ICAgIGlmIChlbCkgZWwuc2Nyb2xsSW50b1ZpZXcoeyBibG9jazogJ25lYXJlc3QnIH0pOwogICAgICAg
IH0KICAgIH0KCgogICAgLyogc2hpZnQtcmFuZ2Utc2VsZWN0LXYxICovCiAgICBsZXQgcmFuZ2VBbmNo
b3JJZCA9IDA7CiAgICBsZXQgcmFuZ2VBbmNob3JDbGlja2VkID0gZmFsc2U7CiAgICBmdW5jdGlvbiBz
ZWxlY3RSYW5nZVRvKGlkKSB7CiAgICAgICAgaWQgPSAraWQ7CiAgICAgICAgY29uc3QgbGlzdCA9ICh0
eXBlb2YgbmF2TGlzdCA9PT0gJ2Z1bmN0aW9uJyA/IG5hdkxpc3QoKSA6IHZpc2libGVMaXN0KCkpOwog
ICAgICAgIGNvbnN0IGIgPSBsaXN0LmZpbmRJbmRleChjID0+ICtjLmlkID09PSBpZCk7CiAgICAgICAg
aWYgKGIgPCAwKSByZXR1cm47CiAgICAgICAgbGV0IGFuY2hvciA9ICtyYW5nZUFuY2hvcklkOwogICAg
ICAgIGxldCBhID0gbGlzdC5maW5kSW5kZXgoYyA9PiArYy5pZCA9PT0gYW5jaG9yKTsKICAgICAgICBp
ZiAoYSA8IDApIHsKICAgICAgICAgICAgYW5jaG9yID0gK3NlbGVjdGVkSWQgfHwgaWQ7CiAgICAgICAg
ICAgIGEgPSBsaXN0LmZpbmRJbmRleChjID0+ICtjLmlkID09PSBhbmNob3IpOwogICAgICAgIH0KICAg
ICAgICBpZiAoYSA8IDApIHsKICAgICAgICAgICAgcmFuZ2VBbmNob3JJZCA9IGlkOyBzZWxlY3RlZElk
ID0gaWQ7IG11bHRpSWRzID0gW2lkXTsgdXBkYXRlTXVsdGlCYWRnZSgpOyByZXR1cm47CiAgICAgICAg
fQogICAgICAgIGlmICghcmFuZ2VBbmNob3JJZCB8fCBsaXN0LmZpbmRJbmRleChjID0+ICtjLmlkID09
PSArcmFuZ2VBbmNob3JJZCkgPCAwKQogICAgICAgICAgICByYW5nZUFuY2hvcklkID0gbGlzdFthXS5p
ZDsKICAgICAgICBjb25zdCBsbyA9IE1hdGgubWluKGEsIGIpLCBoaSA9IE1hdGgubWF4KGEsIGIpOwog
ICAgICAgIG11bHRpSWRzID0gW107CiAgICAgICAgZm9yIChsZXQgaSA9IGxvOyBpIDw9IGhpOyBpKysp
IG11bHRpSWRzLnB1c2goK2xpc3RbaV0uaWQpOwogICAgICAgIHNlbGVjdGVkSWQgPSBpZDsKICAgICAg
ICB1cGRhdGVNdWx0aUJhZGdlKCk7CiAgICAgICAgY29uc3QgZWwgPSBsaXN0RWwucXVlcnlTZWxlY3Rv
cignLm1nLXJvd1tkYXRhLWlkPSInICsgc2VsZWN0ZWRJZCArICciXScpIHx8IGxpc3RFbC5xdWVyeVNl
bGVjdG9yKCcuaXRtW2RhdGEtaWQ9IicgKyBzZWxlY3RlZElkICsgJyJdJyk7CiAgICAgICAgaWYgKGVs
KSBlbC5zY3JvbGxJbnRvVmlldyh7IGJsb2NrOiAnbmVhcmVzdCcgfSk7CiAgICB9CiAgICBmdW5jdGlv
biBzaG93U3JjVGlwKGFuY2hvciwgdGV4dCkgewogICAgICAgIHRleHQgPSBTdHJpbmcodGV4dCB8fCAn
JykudHJpbSgpOwogICAgICAgIGlmICghdGV4dCkgcmV0dXJuOwogICAgICAgIGxldCB0aXAgPSBkb2N1
bWVudC5nZXRFbGVtZW50QnlJZCgnc3JjLXRpcCcpOwogICAgICAgIGlmICghdGlwKSB7CiAgICAgICAg
ICAgIHRpcCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICB0aXAuaWQg
PSAnc3JjLXRpcCc7CiAgICAgICAgICAgIGRvY3VtZW50LmJvZHkuYXBwZW5kQ2hpbGQodGlwKTsKICAg
ICAgICB9CiAgICAgICAgdGlwLnRleHRDb250ZW50ID0gdGV4dDsKICAgICAgICB0aXAuY2xhc3NMaXN0
LmFkZCgnc2hvdycpOwogICAgICAgIGNvbnN0IHIgPSBhbmNob3IuZ2V0Qm91bmRpbmdDbGllbnRSZWN0
KCk7CiAgICAgICAgY29uc3QgdHcgPSB0aXAub2Zmc2V0V2lkdGggfHwgMTYwOwogICAgICAgIGNvbnN0
IHRoID0gdGlwLm9mZnNldEhlaWdodCB8fCAyODsKICAgICAgICBsZXQgbGVmdCA9IHIucmlnaHQgLSB0
dzsKICAgICAgICBsZXQgdG9wID0gci50b3AgLSB0aCAtIDg7CiAgICAgICAgaWYgKGxlZnQgPCA4KSBs
ZWZ0ID0gODsKICAgICAgICBpZiAobGVmdCArIHR3ID4gd2luZG93LmlubmVyV2lkdGggLSA4KSBsZWZ0
ID0gd2luZG93LmlubmVyV2lkdGggLSB0dyAtIDg7CiAgICAgICAgaWYgKHRvcCA8IDgpIHRvcCA9IHIu
Ym90dG9tICsgODsKICAgICAgICB0aXAuc3R5bGUubGVmdCA9IGxlZnQgKyAncHgnOwogICAgICAgIHRp
cC5zdHlsZS50b3AgPSB0b3AgKyAncHgnOwogICAgICAgIGNsZWFyVGltZW91dCh0aXAuX2hpZGVUKTsK
ICAgICAgICB0aXAuX2hpZGVUID0gc2V0VGltZW91dCgoKSA9PiB0aXAuY2xhc3NMaXN0LnJlbW92ZSgn
c2hvdycpLCAyMjAwKTsKICAgIH0KICAgIC8qIGltZy1ob3Zlci1wcmV2aWV3LXY4ICovCiAgICBsZXQg
X19pbWdIb3ZlclRpbWVyID0gMCwgX19pbWdIb3ZlckhpZGVUaW1lciA9IDAsIF9faW1nSG92ZXJLZXkg
PSAnJzsKICAgIGZ1bmN0aW9uIF9faW1nSG92ZXJFbnN1cmUoKSB7CiAgICAgICAgbGV0IGJveCA9IGRv
Y3VtZW50LmdldEVsZW1lbnRCeUlkKCdpbWctaG92ZXItc2lkZScpOwogICAgICAgIGlmICghYm94KSB7
CiAgICAgICAgICAgIGJveCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOyBib3guaWQgPSAn
aW1nLWhvdmVyLXNpZGUnOwogICAgICAgICAgICBjb25zdCBmcmFtZSA9IGRvY3VtZW50LmNyZWF0ZUVs
ZW1lbnQoJ2RpdicpOyBmcmFtZS5jbGFzc05hbWUgPSAnaWhwLWZyYW1lJzsKICAgICAgICAgICAgY29u
c3QgaW0gPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdpbWcnKTsgaW0uYWx0ID0gJyc7CiAgICAgICAg
ICAgIGZyYW1lLmFwcGVuZENoaWxkKGltKTsgYm94LmFwcGVuZENoaWxkKGZyYW1lKTsgZG9jdW1lbnQu
Ym9keS5hcHBlbmRDaGlsZChib3gpOwogICAgICAgIH0KICAgICAgICBsZXQgc3QgPSBkb2N1bWVudC5n
ZXRFbGVtZW50QnlJZCgnaW1nLWhvdmVyLXNpZGUtY3NzJyk7CiAgICAgICAgaWYgKCFzdCkgeyBzdCA9
IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ3N0eWxlJyk7IHN0LmlkID0gJ2ltZy1ob3Zlci1zaWRlLWNz
cyc7IGRvY3VtZW50LmhlYWQuYXBwZW5kQ2hpbGQoc3QpOyB9CiAgICAgICAgc3QudGV4dENvbnRlbnQg
PSAiI2ltZy1ob3Zlci1zaWRle3Bvc2l0aW9uOmZpeGVkO3otaW5kZXg6MTAwMDAwO3JpZ2h0OjZweDt0
b3A6NTAlO3RyYW5zZm9ybTp0cmFuc2xhdGVZKC01MCUpO3BvaW50ZXItZXZlbnRzOm5vbmU7b3BhY2l0
eTowO3Zpc2liaWxpdHk6aGlkZGVuO21heC13aWR0aDptaW4oNjIwcHgsOTJ2dyk7bWF4LWhlaWdodDpt
aW4oOTJ2aCw5MjBweCl9I2ltZy1ob3Zlci1zaWRlLnNob3d7b3BhY2l0eToxO3Zpc2liaWxpdHk6dmlz
aWJsZX0jaW1nLWhvdmVyLXNpZGUgLmlocC1mcmFtZXtwYWRkaW5nOjNweDtiYWNrZ3JvdW5kOiNmZmY7
Ym9yZGVyOjFweCBzb2xpZCAjQzVDRERDO2JvcmRlci1yYWRpdXM6MnB4O2JveC1zaGFkb3c6MCA2cHgg
MThweCByZ2JhKDQ0LDQ2LDU0LC4xMil9I2ltZy1ob3Zlci1zaWRlIGltZ3tkaXNwbGF5OmJsb2NrO21h
eC13aWR0aDptaW4oNjEycHgsOTB2dyk7bWF4LWhlaWdodDptaW4oOTB2aCw5MDBweCk7d2lkdGg6YXV0
bztoZWlnaHQ6YXV0bztvYmplY3QtZml0OmNvbnRhaW47YmFja2dyb3VuZDojZmZmfSI7CiAgICAgICAg
cmV0dXJuIGJveDsKICAgIH0KICAgIHdpbmRvdy5fX2ltZ0hvdmVyU2hvdyA9IGZ1bmN0aW9uKGZpbGUs
IGlkKSB7CiAgICAgICAgY29uc3QgYmFyZSA9IFN0cmluZyhmaWxlIHx8ICcnKS5zcGxpdCgvW1xcXFwv
XS8pLnBvcCgpOyBpZiAoIWJhcmUpIHJldHVybjsKICAgICAgICBjb25zdCBib3ggPSBfX2ltZ0hvdmVy
RW5zdXJlKCk7IGNvbnN0IGltZyA9IGJveC5xdWVyeVNlbGVjdG9yKCdpbWcnKTsgaWYgKCFpbWcpIHJl
dHVybjsKICAgICAgICBib3guY2xhc3NMaXN0LmFkZCgnc2hvdycpOwogICAgICAgIGltZy5vbmVycm9y
ID0gKCkgPT4gewogICAgICAgICAgICBpbWcub25lcnJvciA9ICgpID0+IHsgaW1nLm9uZXJyb3IgPSBu
dWxsOyB0cnkgeyBjb25zdCBjID0gdGh1bWJDYWNoZSAmJiB0aHVtYkNhY2hlLmdldChTdHJpbmcoaWQp
KTsgaWYgKGMpIGltZy5zcmMgPSBjOyB9IGNhdGNoIChlKSB7fSB9OwogICAgICAgICAgICBpbWcuc3Jj
ID0gU1RPUkVfQkFTRSArICd0aF8nICsgYmFyZS5yZXBsYWNlKC9cLlteLl0rJC8sICcnKSArICcuanBn
JzsKICAgICAgICB9OwogICAgICAgIGltZy5vbmxvYWQgPSAoKSA9PiB7IGltZy5vbmVycm9yID0gbnVs
bDsgfTsKICAgICAgICBpbWcuZGF0YXNldC5iYXJlID0gYmFyZTsgaW1nLnNyYyA9IFNUT1JFX0JBU0Ug
KyBiYXJlOwogICAgfTsKICAgIHdpbmRvdy5fX2ltZ0hvdmVyQ2xlYXJVaSA9IGZ1bmN0aW9uKCkgewog
ICAgICAgIF9faW1nSG92ZXJLZXkgPSAnJzsKICAgICAgICBpZiAoX19pbWdIb3ZlclRpbWVyKSB7IGNs
ZWFyVGltZW91dChfX2ltZ0hvdmVyVGltZXIpOyBfX2ltZ0hvdmVyVGltZXIgPSAwOyB9CiAgICAgICAg
aWYgKF9faW1nSG92ZXJIaWRlVGltZXIpIHsgY2xlYXJUaW1lb3V0KF9faW1nSG92ZXJIaWRlVGltZXIp
OyBfX2ltZ0hvdmVySGlkZVRpbWVyID0gMDsgfQogICAgICAgIGNvbnN0IGJveCA9IGRvY3VtZW50Lmdl
dEVsZW1lbnRCeUlkKCdpbWctaG92ZXItc2lkZScpOyBpZiAoYm94KSBib3guY2xhc3NMaXN0LnJlbW92
ZSgnc2hvdycpOwogICAgICAgIGNvbnN0IGltZyA9IGJveCAmJiBib3gucXVlcnlTZWxlY3RvcignaW1n
Jyk7CiAgICAgICAgaWYgKGltZykgeyBpbWcub25sb2FkID0gbnVsbDsgaW1nLm9uZXJyb3IgPSBudWxs
OyBpbWcucmVtb3ZlQXR0cmlidXRlKCdzcmMnKTsgZGVsZXRlIGltZy5kYXRhc2V0LmJhcmU7IH0KICAg
IH07CiAgICB3aW5kb3cuX19pbWdIb3ZlckhpZGUgPSBmdW5jdGlvbigpIHsgd2luZG93Ll9faW1nSG92
ZXJDbGVhclVpKCk7IH07CiAgICBmdW5jdGlvbiBiaW5kSW1nSG92ZXJQcmV2aWV3KGVsLCBpZCwgZmls
ZSkgewogICAgICAgIGlmICghZWwpIHJldHVybjsKICAgICAgICBjb25zdCBiYXJlID0gU3RyaW5nKGZp
bGUgfHwgJycpLnNwbGl0KC9bXFxcXC9dLykucG9wKCk7IGlmICghYmFyZSkgcmV0dXJuOwogICAgICAg
IGNvbnN0IGtleSA9IFN0cmluZyhpZCkgKyAnfCcgKyBiYXJlOwogICAgICAgIGVsLnN0eWxlLmN1cnNv
ciA9ICd6b29tLWluJzsKICAgICAgICBlbC5hZGRFdmVudExpc3RlbmVyKCdtb3VzZWVudGVyJywgKCkg
PT4gewogICAgICAgICAgICBpZiAoX19pbWdIb3ZlckhpZGVUaW1lcikgeyBjbGVhclRpbWVvdXQoX19p
bWdIb3ZlckhpZGVUaW1lcik7IF9faW1nSG92ZXJIaWRlVGltZXIgPSAwOyB9CiAgICAgICAgICAgIF9f
aW1nSG92ZXJLZXkgPSBrZXk7CiAgICAgICAgICAgIGlmIChfX2ltZ0hvdmVyVGltZXIpIGNsZWFyVGlt
ZW91dChfX2ltZ0hvdmVyVGltZXIpOwogICAgICAgICAgICBfX2ltZ0hvdmVyVGltZXIgPSBzZXRUaW1l
b3V0KCgpID0+IHsgaWYgKF9faW1nSG92ZXJLZXkgPT09IGtleSkgdHJ5IHsgd2luZG93Ll9faW1nSG92
ZXJTaG93KGJhcmUsIGlkKTsgfSBjYXRjaCAoZSkge30gfSwgNjApOwogICAgICAgIH0pOwogICAgICAg
IGVsLmFkZEV2ZW50TGlzdGVuZXIoJ21vdXNlbGVhdmUnLCAoKSA9PiB7CiAgICAgICAgICAgIGlmIChf
X2ltZ0hvdmVyVGltZXIpIHsgY2xlYXJUaW1lb3V0KF9faW1nSG92ZXJUaW1lcik7IF9faW1nSG92ZXJU
aW1lciA9IDA7IH0KICAgICAgICAgICAgX19pbWdIb3ZlckhpZGVUaW1lciA9IHNldFRpbWVvdXQoKCkg
PT4geyBpZiAoIV9faW1nSG92ZXJLZXkgfHwgX19pbWdIb3ZlcktleSA9PT0ga2V5KSB3aW5kb3cuX19p
bWdIb3ZlckhpZGUoKTsgfSwgNzApOwogICAgICAgIH0pOwogICAgfQogICAgZnVuY3Rpb24gaGFuZGxl
SXRlbUNsaWNrKGUsIGMpIHsKICAgICAgICBpZiAoZS5zaGlmdEtleSkgewogICAgICAgICAgICBlLnBy
ZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgIGNvbnN0IGxpc3Qg
PSAodHlwZW9mIG5hdkxpc3QgPT09ICdmdW5jdGlvbicgPyBuYXZMaXN0KCkgOiB2aXNpYmxlTGlzdCgp
KTsKICAgICAgICAgICAgY29uc3QgYW5jaG9yT2sgPSByYW5nZUFuY2hvckNsaWNrZWQgJiYgcmFuZ2VB
bmNob3JJZCAmJiBsaXN0LnNvbWUoeCA9PiAreC5pZCA9PT0gK3JhbmdlQW5jaG9ySWQpOwogICAgICAg
ICAgICBpZiAoIWFuY2hvck9rKSByYW5nZUFuY2hvcklkID0gc2VsZWN0ZWRJZCB8fCBjLmlkOwogICAg
ICAgICAgICByYW5nZUFuY2hvckNsaWNrZWQgPSB0cnVlOwogICAgICAgICAgICBzZWxlY3RSYW5nZVRv
KGMuaWQpOwogICAgICAgICAgICByZXR1cm4gdHJ1ZTsKICAgICAgICB9CiAgICAgICAgaWYgKGUuY3Ry
bEtleSB8fCBlLm1ldGFLZXkpIHsKICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOyBlLnN0b3BQ
cm9wYWdhdGlvbigpOwogICAgICAgICAgICB0b2dnbGVNdWx0aShjLmlkKTsKICAgICAgICAgICAgcmV0
dXJuIHRydWU7CiAgICAgICAgfQogICAgICAgIHJhbmdlQW5jaG9ySWQgPSBjLmlkOwogICAgICAgIHJh
bmdlQW5jaG9yQ2xpY2tlZCA9IHRydWU7CiAgICAgICAgcmV0dXJuIGZhbHNlOwogICAgfQogICAgZnVu
Y3Rpb24gdG9nZ2xlTXVsdGkoaWQpIHsKICAgICAgICBpZCA9ICtpZDsKICAgICAgICBjb25zdCBpID0g
bXVsdGlJZHMuaW5kZXhPZihpZCk7CiAgICAgICAgaWYgKGkgPj0gMCkgbXVsdGlJZHMuc3BsaWNlKGks
IDEpOwogICAgICAgIGVsc2UgbXVsdGlJZHMucHVzaChpZCk7CiAgICAgICAgc2VsZWN0ZWRJZCA9IGlk
OwogICAgICAgIHJhbmdlQW5jaG9ySWQgPSBpZDsKICAgICAgICByYW5nZUFuY2hvckNsaWNrZWQgPSB0
cnVlOwogICAgICAgIHVwZGF0ZU11bHRpQmFkZ2UoKTsKICAgIH0KCiAgICBmdW5jdGlvbiByZW5kZXIo
KSB7CiAgICAgICAgaGlkZVBhdGhUaXAoKTsKCiAgICAgICAgY29uc3QgdmlzaWJsZSA9IHZpc2libGVM
aXN0KCk7CiAgICAgICAgY29uc3QgcGlubmVkTiA9IGFsbENsaXBzLmZpbHRlcihjID0+IGlzUGlubmVk
KGMpKS5sZW5ndGg7CiAgICAgICAgY29uc3QgcGluQ250ICA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlk
KCdwaW4tY250Jyk7CiAgICAgICAgcGluQ250LnRleHRDb250ZW50ICAgPSBwaW5uZWROOwogICAgICAg
IHBpbkNudC5zdHlsZS5kaXNwbGF5ID0gcGlubmVkTiA/ICcnIDogJ25vbmUnOwogICAgICAgIGNvbnN0
IGxvYWRlZCA9IGFsbENsaXBzLmxlbmd0aDsKICAgICAgICBjb25zdCBzaG93bkNvdW50ID0gdmlzaWJs
ZS5sZW5ndGg7CiAgICAgICAgY29uc3Qgc2hvd1RvdGFsID0gZGlza1RvdGFsID4gMCA/IGRpc2tUb3Rh
bCA6IChsb2FkZWQgfHwgMCk7CiAgICAgICAgY29uc3QgcU9uID0gU3RyaW5nKHF1ZXJ5IHx8ICcnKS50
cmltKCkubGVuZ3RoID4gMDsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYmFyLXR4dCcp
LnRleHRDb250ZW50ID0gcU9uCiAgICAgICAgICAgID8gKHNob3duQ291bnQgKyAnIOadoScpCiAgICAg
ICAgICAgIDogKGRpc2tUb3RhbCA+IGxvYWRlZCA/IChzaG93bkNvdW50ICsgJyAvICcgKyBzaG93VG90
YWwgKyAnIOadoScpIDogKHNob3dUb3RhbCArICcg5p2hJykpOwogICAgICAgIGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCdlbXB0eS10eHQnKS50ZXh0Q29udGVudCA9IEVNUFRZX01TR1tjdXJUYWJdIHx8IEVN
UFRZX01TRy5hbGw7CgogICAgICAgIGNvbnN0IGlkU2V0ID0gbmV3IFNldChhbGxDbGlwcy5tYXAoYyA9
PiArYy5pZCkpOwogICAgICAgIG11bHRpSWRzID0gbXVsdGlJZHMuZmlsdGVyKGlkID0+IGlkU2V0Lmhh
cyhpZCkpOwogICAgICAgIHVwZGF0ZU11bHRpQmFkZ2UoKTsKCiAgICAgICAgY29uc3Qgc2hvd24gPSB2
aXNpYmxlOwoKICAgICAgICBsaXN0RWwucXVlcnlTZWxlY3RvckFsbCgnLml0bSwgI2xpc3QtbW9yZScp
LmZvckVhY2goZSA9PiBlLnJlbW92ZSgpKTsKICAgICAgICBpZiAoYm9vdExvYWRpbmcpIHsKICAgICAg
ICAgICAgaWYgKHNrZWxFbCkgc2tlbEVsLmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAgICAgICAgICAgIGVt
cHR5RWwuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICAgICAgdXBkYXRlVG9wQnRuKCk7CiAg
ICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgaWYgKHNrZWxFbCkgc2tlbEVsLmNsYXNz
TGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgaWYgKCF2aXNpYmxlLmxlbmd0aCkgewogICAgICAgICAg
ICBpZiAoc2VsZWN0Rmlyc3RPblNob3cpIHsKICAgICAgICAgICAgICAgIHNlbGVjdEZpcnN0T25TaG93
ID0gZmFsc2U7CiAgICAgICAgICAgICAgICBzZWxlY3RlZElkID0gMDsKICAgICAgICAgICAgICAgIGNs
ZWFyTXVsdGkoKTsKICAgICAgICAgICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSAwOwogICAgICAgICAg
ICB9CiAgICAgICAgICAgIGVtcHR5RWwuY2xhc3NMaXN0LmFkZCgnb24nKTsKICAgICAgICAgICAgdXBk
YXRlVG9wQnRuKCk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgZW1wdHlFbC5j
bGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgIGNvbnN0IGZyYWcgPSBkb2N1bWVudC5jcmVhdGVE
b2N1bWVudEZyYWdtZW50KCk7CiAgICAgICAgY29uc3QgYmxvY2tzID0gYnVpbGRQaW5uZWRCbG9ja3Mo
c2hvd24pOwogICAgICAgIGxldCBudW0gPSAwOwogICAgICAgIGJsb2Nrcy5mb3JFYWNoKGIgPT4gewog
ICAgICAgICAgICBudW0gKz0gMTsKICAgICAgICAgICAgaWYgKGIua2luZCA9PT0gJ2dyb3VwJyAmJiBi
Lml0ZW1zLmxlbmd0aCA+IDEpCiAgICAgICAgICAgICAgICBmcmFnLmFwcGVuZENoaWxkKG1ha2VHcm91
cEl0ZW0oYi5pdGVtcywgbnVtKSk7CiAgICAgICAgICAgIGVsc2UKICAgICAgICAgICAgICAgIGZyYWcu
YXBwZW5kQ2hpbGQobWFrZUl0ZW0oYi5pdGVtc1swXSwgbnVtKSk7CiAgICAgICAgfSk7CiAgICAgICAg
bGlzdEVsLmFwcGVuZENoaWxkKGZyYWcpOwogICAgICAgIHVwZGF0ZU1vcmVGb290ZXIoZGlza1RvdGFs
KTsKICAgICAgICBpZiAoc2VsZWN0Rmlyc3RPblNob3cpIHsKICAgICAgICAgICAgc2VsZWN0Rmlyc3RP
blNob3cgPSBmYWxzZTsKICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IHZpc2libGVbMF0uaWQ7CiAgICAg
ICAgICAgIGNsZWFyTXVsdGkoKTsKICAgICAgICAgICAgbGlzdEVsLnNjcm9sbFRvcCA9IDA7CiAgICAg
ICAgfSBlbHNlIGlmICghdmlzaWJsZS5zb21lKGMgPT4gYy5pZCA9PSBzZWxlY3RlZElkKSkgewogICAg
ICAgICAgICBzZWxlY3RlZElkID0gdmlzaWJsZVswXS5pZDsKICAgICAgICAgICAgcmFuZ2VBbmNob3JJ
ZCA9IHNlbGVjdGVkSWQ7CiAgICAgICAgICAgIHJhbmdlQW5jaG9yQ2xpY2tlZCA9IGZhbHNlOwogICAg
ICAgIH0gZWxzZSBpZiAoIXJhbmdlQW5jaG9ySWQpIHsKICAgICAgICAgICAgcmFuZ2VBbmNob3JJZCA9
IHNlbGVjdGVkSWQ7CiAgICAgICAgfQogICAgICAgIHN5bmNJdGVtSGlnaGxpZ2h0KCk7CiAgICAgICAg
dXBkYXRlVG9wQnRuKCk7CiAgICAgICAgaWYgKHdpbmRvdy5fX3BlbmRpbmdKdW1wSWQpIHsKICAgICAg
ICAgICAgY29uc3QgamlkID0gK3dpbmRvdy5fX3BlbmRpbmdKdW1wSWQ7CiAgICAgICAgICAgIGNvbnN0
IGVsID0gbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5tZy1yb3dbZGF0YS1pZD0iJyArIGppZCArICciXScp
IHx8IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcuaXRtW2RhdGEtaWQ9IicgKyBqaWQgKyAnIl0nKTsKICAg
ICAgICAgICAgaWYgKGVsKSB7CiAgICAgICAgICAgICAgICB3aW5kb3cuX19wZW5kaW5nSnVtcElkID0g
MDsKICAgICAgICAgICAgICAgIHdpbmRvdy5fX2p1bXBMb2FkVHJpZXMgPSAwOwogICAgICAgICAgICAg
ICAgc2VsZWN0ZWRJZCA9IGppZDsKICAgICAgICAgICAgICAgIHJlcXVlc3RBbmltYXRpb25GcmFtZSgo
KSA9PiB7CiAgICAgICAgICAgICAgICAgICAgY29uc3Qgbm9kZSA9IGxpc3RFbC5xdWVyeVNlbGVjdG9y
KCcubWctcm93W2RhdGEtaWQ9IicgKyBqaWQgKyAnIl0nKSB8fCBsaXN0RWwucXVlcnlTZWxlY3Rvcign
Lml0bVtkYXRhLWlkPSInICsgamlkICsgJyJdJyk7CiAgICAgICAgICAgICAgICAgICAgaWYgKCFub2Rl
KSByZXR1cm47CiAgICAgICAgICAgICAgICAgICAgbm9kZS5zY3JvbGxJbnRvVmlldyh7IGJsb2NrOiAn
Y2VudGVyJyB9KTsKICAgICAgICAgICAgICAgICAgICBub2RlLmNsYXNzTGlzdC5hZGQoJ2p1bXAtZmxh
c2gnKTsKICAgICAgICAgICAgICAgICAgICBzZXRUaW1lb3V0KCgpID0+IG5vZGUuY2xhc3NMaXN0LnJl
bW92ZSgnanVtcC1mbGFzaCcpLCA5MDApOwogICAgICAgICAgICAgICAgICAgIHN5bmNJdGVtSGlnaGxp
Z2h0KCk7CiAgICAgICAgICAgICAgICB9KTsKICAgICAgICAgICAgfSBlbHNlIGlmIChhbGxDbGlwcy5s
ZW5ndGggPCBkaXNrVG90YWwgJiYgKHdpbmRvdy5fX2p1bXBMb2FkVHJpZXMgfHwgMCkgPCA0MCkgewog
ICAgICAgICAgICAgICAgd2luZG93Ll9fanVtcExvYWRUcmllcyA9ICh3aW5kb3cuX19qdW1wTG9hZFRy
aWVzIHx8IDApICsgMTsKICAgICAgICAgICAgICAgIHJlcXVlc3RNb3JlKCk7CiAgICAgICAgICAgIH0g
ZWxzZSBpZiAoY3VyVGFiICE9PSAnYWxsJyAmJiAhd2luZG93Ll9fanVtcEZlbGxCYWNrKSB7CiAgICAg
ICAgICAgICAgICAvLyBJdGVtIGdvbmUgZnJvbSB0aGlzIHRhYiAoZS5nLiB1bnBpbm5lZCkg4oCUIGZh
bGwgYmFjayB0byDlhajpg6ggb25jZQogICAgICAgICAgICAgICAgd2luZG93Ll9fanVtcEZlbGxCYWNr
ID0gdHJ1ZTsKICAgICAgICAgICAgICAgIHdpbmRvdy5fX2p1bXBMb2FkVHJpZXMgPSAwOwogICAgICAg
ICAgICAgICAgY3VyVGFiID0gJ2FsbCc7CiAgICAgICAgICAgICAgICBtYXJrVGFiKCdhbGwnKTsKICAg
ICAgICAgICAgICAgIHJlcXVlc3RWaWV3KCk7CiAgICAgICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAg
ICAgICB3aW5kb3cuX19wZW5kaW5nSnVtcElkID0gMDsKICAgICAgICAgICAgICAgIHdpbmRvdy5fX2p1
bXBMb2FkVHJpZXMgPSAwOwogICAgICAgICAgICAgICAgaWYgKGFsbENsaXBzLnNvbWUoYyA9PiArYy5p
ZCA9PT0gamlkKSkKICAgICAgICAgICAgICAgICAgICBzZWxlY3RlZElkID0gamlkOwogICAgICAgICAg
ICAgICAgc3luY0l0ZW1IaWdobGlnaHQoKTsKICAgICAgICAgICAgfQogICAgICAgIH0KICAgICAgICBy
ZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4gewogICAgICAgICAgICBpZiAoYWxsQ2xpcHMubGVuZ3Ro
IDwgZGlza1RvdGFsCiAgICAgICAgICAgICAgICAmJiBsaXN0RWwuc2Nyb2xsSGVpZ2h0IDw9IGxpc3RF
bC5jbGllbnRIZWlnaHQgKyAyMCkKICAgICAgICAgICAgICAgIHJlcXVlc3RNb3JlKCk7CiAgICAgICAg
ICAgIHNjaGVkdWxlRmlsZUdvbmVDaGVjaygpOwogICAgICAgIH0pOwogICAgfQoKICAgIGNvbnN0IFNW
RyA9IHsKICAgICAgICB0ZXh0OiAgIGA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIg
c3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMiI+PHBhdGggZD0iTTQgN1Y0aDE2djNN
OSAyMGg2TTEyIDR2MTYiLz48L3N2Zz5gLAogICAgICAgIG1kOiAgICAgYDxzdmcgdmlld0JveD0iMCAw
IDI0IDI0IiBmaWxsPSJjdXJyZW50Q29sb3IiPjx0ZXh0IHg9IjEyIiB5PSIxNyIgdGV4dC1hbmNob3I9
Im1pZGRsZSIgZm9udC1zaXplPSIxNSIgZm9udC13ZWlnaHQ9IjgwMCIgZm9udC1mYW1pbHk9IlNlZ29l
IFVJLE1pY3Jvc29mdCBZYUhlaSxzYW5zLXNlcmlmIj5NPC90ZXh0Pjwvc3ZnPmAsCiAgICAgICAgaW1h
Z2U6ICBgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENv
bG9yIiBzdHJva2Utd2lkdGg9IjEuOCI+PHJlY3QgeD0iMyIgeT0iNSIgd2lkdGg9IjE4IiBoZWlnaHQ9
IjE0IiByeD0iMiIvPjxjaXJjbGUgY3g9IjguNSIgY3k9IjEwIiByPSIxLjUiIGZpbGw9ImN1cnJlbnRD
b2xvciIgc3Ryb2tlPSJub25lIi8+PHBhdGggZD0iTTMgMTZsNS01IDQgNCAzLTMgNiA2Ii8+PC9zdmc+
YCwKICAgICAgICB2aWRlbzogIGA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ry
b2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44Ij48cmVjdCB4PSIzIiB5PSI2IiB3aWR0
aD0iMTQiIGhlaWdodD0iMTIiIHJ4PSIyIi8+PHBhdGggZD0iTTE3IDkuNWw0LTIuNXYxMGwtNC0yLjVW
OS41eiIgZmlsbD0iY3VycmVudENvbG9yIiBzdHJva2U9Im5vbmUiLz48cGF0aCBkPSJNOC41IDEwLjJ2
My42bDMuMi0xLjgtMy4yLTEuOHoiIGZpbGw9ImN1cnJlbnRDb2xvciIgc3Ryb2tlPSJub25lIi8+PC9z
dmc+YCwKICAgICAgICBmb2xkZXI6IGA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0iY3VycmVu
dENvbG9yIj48cGF0aCBkPSJNMTAgNEg0Yy0xLjEgMC0yIC45LTIgMnYxMmMwIDEuMS45IDIgMiAyaDE2
YzEuMSAwIDItLjkgMi0yVjhjMC0xLjEtLjktMi0yLTJoLThsLTItMnoiLz48L3N2Zz5gLAogICAgICAg
IHppcDogICAgYDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJl
bnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxwYXRoIGQ9Ik02IDNoOWw1IDV2MTNhMSAxIDAgMCAx
LTEgMUg2YTEgMSAwIDAgMS0xLTFWNGExIDEgMCAwIDEgMS0xeiIvPjxwYXRoIGQ9Ik0xNCAzdjZoNiIv
Pjwvc3ZnPmAsCiAgICAgICAgYWhrOiAgICBgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9ImN1
cnJlbnRDb2xvciI+PHRleHQgeD0iMTIiIHk9IjE3IiB0ZXh0LWFuY2hvcj0ibWlkZGxlIiBmb250LXNp
emU9IjE0IiBmb250LXdlaWdodD0iNzAwIj5IPC90ZXh0Pjwvc3ZnPmAsCiAgICAgICAgbG5rOiAgICBg
PHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBz
dHJva2Utd2lkdGg9IjEuOCI+PHBhdGggZD0iTTEwIDEzYTUgNSAwIDAgMCA3LjA3IDBsMi4xMi0yLjEy
YTUgNSAwIDAgMC03LjA3LTcuMDdMMTEgNSIvPjxwYXRoIGQ9Ik0xNCAxMWE1IDUgMCAwIDAtNy4wNyAw
TDQuOCAxMy4xMmE1IDUgMCAxIDAgNy4wNyA3LjA3TDEzIDE5Ii8+PC9zdmc+YCwKICAgICAgICBkb2M6
ICAgIGA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29s
b3IiIHN0cm9rZS13aWR0aD0iMS44Ij48cGF0aCBkPSJNNyAzaDdsNSA1djEzYTEgMSAwIDAgMS0xIDFI
N2ExIDEgMCAwIDEtMS0xVjRhMSAxIDAgMCAxIDEtMXoiLz48cGF0aCBkPSJNMTQgM3Y2aDYiLz48L3N2
Zz5gLAogICAgICAgIG11bHRpOiAgYDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBz
dHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxyZWN0IHg9IjciIHk9IjciIHdp
ZHRoPSIxMiIgaGVpZ2h0PSIxNCIgcng9IjEuNSIvPjxwYXRoIGQ9Ik01IDE3VjVhMSAxIDAgMCAxIDEt
MWgxMCIvPjwvc3ZnPmAKICAgIH07CgogICAgZnVuY3Rpb24gZmlsZUV4dChwYXRoKSB7CiAgICAgICAg
Y29uc3QgYmFzZSA9IFN0cmluZyhwYXRoIHx8ICcnKS5zcGxpdCgvW1xcL10vKS5wb3AoKSB8fCAnJzsK
ICAgICAgICBjb25zdCBpID0gYmFzZS5sYXN0SW5kZXhPZignLicpOwogICAgICAgIHJldHVybiBpID4g
MCA/IGJhc2Uuc2xpY2UoaSArIDEpLnRvTG93ZXJDYXNlKCkgOiAnJzsKICAgIH0KICAgIGNvbnN0IGlz
SW1hZ2VFeHQgPSBlID0+IFsncG5nJywnanBnJywnanBlZycsJ2dpZicsJ3dlYnAnLCdibXAnLCdpY28n
LCd0aWYnLCd0aWZmJywnc3ZnJ10uaW5jbHVkZXMoZSk7CiAgICBjb25zdCBpc1ZpZGVvRXh0ID0gZSA9
PiBbJ21wNCcsJ21rdicsJ2F2aScsJ21vdicsJ3dtdicsJ2ZsdicsJ3dlYm0nLCdtNHYnLCdtcGVnJywn
bXBnJywndHMnLCdtMnRzJywnM2dwJywncm0nLCdybXZiJ10uaW5jbHVkZXMoZSk7CiAgICBjb25zdCBp
c1ppcEV4dCAgID0gZSA9PiBbJ3ppcCcsJ3JhcicsJzd6JywndGFyJywnZ3onLCdiejInXS5pbmNsdWRl
cyhlKTsKCiAgICBmdW5jdGlvbiBpY29uRm9yRmlsZXMoZmlsZXMpIHsKICAgICAgICBpZiAoIWZpbGVz
Lmxlbmd0aCkgICAgcmV0dXJuIHsgY2xzOiAnZmlsZSBmdC1kb2MnLCBzdmc6IFNWRy5kb2MgfTsKICAg
ICAgICBpZiAoZmlsZXMubGVuZ3RoID4gMSkgcmV0dXJuIHsgY2xzOiAnZmlsZSBmdC1sbmsnLCBzdmc6
IFNWRy5tdWx0aSB9OwogICAgICAgIGNvbnN0IGV4dCA9IGZpbGVFeHQoZmlsZXNbMF0pOwogICAgICAg
IGlmICghZXh0KSAgICAgICAgICAgICAgcmV0dXJuIHsgY2xzOiAnZmlsZSBmdC1kaXInLCBzdmc6IFNW
Ry5mb2xkZXIgfTsKICAgICAgICBpZiAoaXNJbWFnZUV4dChleHQpKSAgIHJldHVybiB7IGNsczogJ2Zp
bGUgZnQtaW1nJywgc3ZnOiBTVkcuaW1hZ2UgfTsKICAgICAgICBpZiAoaXNWaWRlb0V4dChleHQpKSAg
IHJldHVybiB7IGNsczogJ2ZpbGUgZnQtdmlkJywgc3ZnOiAoU1ZHLnZpZGVvIHx8IFNWRy5kb2MpIH07
CiAgICAgICAgaWYgKGlzWmlwRXh0KGV4dCkpICAgICByZXR1cm4geyBjbHM6ICdmaWxlIGZ0LXppcCcs
IHN2ZzogU1ZHLnppcCB9OwogICAgICAgIGlmIChleHQgPT09ICdhaGsnKSAgICAgcmV0dXJuIHsgY2xz
OiAnZmlsZSBmdC1haGsnLCBzdmc6IFNWRy5haGsgfTsKICAgICAgICBpZiAoZXh0ID09PSAnbG5rJykg
ICAgIHJldHVybiB7IGNsczogJ2ZpbGUgZnQtbG5rJywgc3ZnOiBTVkcubG5rIH07CiAgICAgICAgcmV0
dXJuIHsgY2xzOiAnZmlsZSBmdC1kb2MnLCBzdmc6IFNWRy5kb2MgfTsKICAgIH0KCiAgICBmdW5jdGlv
biBzcmNXaW5MYWJlbChjKSB7CiAgICAgICAgY29uc3QgdCA9IFN0cmluZyhjICYmIGMuc3JjVGl0bGUg
fHwgJycpLnRyaW0oKTsKICAgICAgICBpZiAodCkgcmV0dXJuIHQ7CiAgICAgICAgcmV0dXJuIFN0cmlu
ZyhjICYmIGMuc3JjRXhlIHx8ICcnKS5yZXBsYWNlKC9cLmV4ZSQvaSwgJycpOwogICAgfQogICAgZnVu
Y3Rpb24gc3JjVGl0bGVIdG1sKGMpIHsKICAgICAgICAvLyDliJfooajkuK3pl7Qv5Y+z5L6n5LiN5YaN
5pi+56S656qX5Y+j5qCH6aKY77yM5p2l5rqQ5Y+q5L+d55WZ5Y+z5L6n5Zu+5qCH5oKs5YGc5o+Q56S6
CiAgICAgICAgcmV0dXJuICcnOwogICAgfQogICAgZnVuY3Rpb24gZXhwYW5kQ2hldnJvbihvcGVuKSB7
CiAgICAgICAgcmV0dXJuIG9wZW4KICAgICAgICAgICAgPyBgPHN2ZyB2aWV3Qm94PSIwIDAgMTYgMTYi
IHdpZHRoPSIxNCIgaGVpZ2h0PSIxNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0
cm9rZS13aWR0aD0iMS44IiBzdHJva2UtbGluZWNhcD0icm91bmQiPjxwb2x5bGluZSBwb2ludHM9IjQg
MTAgOCA2IDEyIDEwIi8+PC9zdmc+PHNwYW4+5pS26LW3PC9zcGFuPmAKICAgICAgICAgICAgOiBgPHN2
ZyB2aWV3Qm94PSIwIDAgMTYgMTYiIHdpZHRoPSIxNCIgaGVpZ2h0PSIxNCIgZmlsbD0ibm9uZSIgc3Ry
b2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44IiBzdHJva2UtbGluZWNhcD0icm91bmQi
Pjxwb2x5bGluZSBwb2ludHM9IjQgNiA4IDEwIDEyIDYiLz48L3N2Zz48c3Bhbj7lsZXlvIA8L3NwYW4+
YDsKICAgIH0KICAgIGZ1bmN0aW9uIGxpc3RFeHBhbmRNYXhQeCgpIHsKICAgICAgICBjb25zdCBoID0g
KGxpc3RFbCAmJiBsaXN0RWwuY2xpZW50SGVpZ2h0KSB8fCAzNjA7CiAgICAgICAgLy8g5Yeg5LmO5Y2g
5ruh5YiX6KGo77yM5bqV6YOo55WZ57qm5LiA6KGMCiAgICAgICAgcmV0dXJuIE1hdGgubWF4KDk2LCBo
IC0gMjgpOwogICAgfQogICAgZnVuY3Rpb24gYXBwbHlFeHBhbmRlZFByZXZpZXcocHJldiwgZnVsbFRl
eHQpIHsKICAgICAgICBjb25zdCBtYXhIID0gbGlzdEV4cGFuZE1heFB4KCk7CiAgICAgICAgcHJldi5z
dHlsZS5tYXhIZWlnaHQgPSBtYXhIICsgJ3B4JzsKICAgICAgICBwcmV2LmNsYXNzTGlzdC5hZGQoJ2V4
cGFuZGVkJyk7CiAgICAgICAgc2V0SGxUZXh0KHByZXYsIGZ1bGxUZXh0KTsKICAgICAgICAvLyDku43m
uqLlh7rvvJrmiKrmlq3lubblnKjmnKvlsL7liqDjgIwgLi4u44CNCiAgICAgICAgaWYgKHByZXYuc2Ny
b2xsSGVpZ2h0IDw9IHByZXYuY2xpZW50SGVpZ2h0ICsgMikKICAgICAgICAgICAgcmV0dXJuOwogICAg
ICAgIGxldCBsbyA9IDAsIGhpID0gZnVsbFRleHQubGVuZ3RoLCBiZXN0ID0gMDsKICAgICAgICB3aGls
ZSAobG8gPD0gaGkpIHsKICAgICAgICAgICAgY29uc3QgbWlkID0gKGxvICsgaGkpID4+IDE7CiAgICAg
ICAgICAgIHNldEhsVGV4dChwcmV2LCBmdWxsVGV4dC5zbGljZSgwLCBtaWQpICsgJyAuLi4nKTsKICAg
ICAgICAgICAgaWYgKHByZXYuc2Nyb2xsSGVpZ2h0IDw9IHByZXYuY2xpZW50SGVpZ2h0ICsgMikgewog
ICAgICAgICAgICAgICAgYmVzdCA9IG1pZDsKICAgICAgICAgICAgICAgIGxvID0gbWlkICsgMTsKICAg
ICAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgICAgIGhpID0gbWlkIC0gMTsKICAgICAgICAgICAg
fQogICAgICAgIH0KICAgICAgICBzZXRIbFRleHQocHJldiwgZnVsbFRleHQuc2xpY2UoMCwgYmVzdCkg
KyAnIC4uLicpOwogICAgfQogICAgZnVuY3Rpb24gY29sbGFwc2VQcmV2aWV3KHByZXYsIGZ1bGxUZXh0
KSB7CiAgICAgICAgcHJldi5jbGFzc0xpc3QucmVtb3ZlKCdleHBhbmRlZCcpOwogICAgICAgIHByZXYu
c3R5bGUubWF4SGVpZ2h0ID0gJyc7CiAgICAgICAgc2V0SGxUZXh0KHByZXYsIGZ1bGxUZXh0KTsKICAg
IH0KCiAgICBmdW5jdGlvbiBmYXZHcm91cE9mKGMpIHsKICAgICAgICByZXR1cm4gU3RyaW5nKGMgJiYg
Yy5mYXZHcm91cCB8fCAnJykudHJpbSgpOwogICAgfQogICAgZnVuY3Rpb24gY2xpcENvbnRlbnRQcmV2
aWV3KGMpIHsKICAgICAgICBjb25zdCB0eXBlID0gbm9ybVR5cGUoYy50eXBlKTsKICAgICAgICBpZiAo
dHlwZSA9PT0gJ2ltYWdlJykgcmV0dXJuICdb5Zu+5YOPXScgKyAoYy53aWR0aCAmJiBjLmhlaWdodCA/
ICgnICcgKyBjLndpZHRoICsgJ8OXJyArIGMuaGVpZ2h0KSA6ICcnKTsKICAgICAgICBpZiAodHlwZSA9
PT0gJ2ZpbGUnKSB7CiAgICAgICAgICAgIGNvbnN0IGZpbGVzID0gU3RyaW5nKGMucHJldmlldyB8fCBj
LmRhdGEgfHwgJycpLnNwbGl0KC9ccj9cbi8pLmZpbHRlcihCb29sZWFuKTsKICAgICAgICAgICAgcmV0
dXJuIGZpbGVzLm1hcChmID0+IGYuc3BsaXQoL1tcXC9dLykucG9wKCkpLmpvaW4oJyDCtyAnKSB8fCAn
W+aWh+S7tl0nOwogICAgICAgIH0KICAgICAgICBsZXQgX3AgPSBTdHJpbmcoYy5wcmV2aWV3IHx8IGMu
ZGF0YSB8fCAnJyk7CiAgICAgICAgeyBjb25zdCBfbiA9IE51bWJlcihjLmNoYXJDb3VudCkgfHwgMDsg
aWYgKF9uID4gX3AubGVuZ3RoICYmIF9wLmxlbmd0aCkgX3AgKz0gJy4uLic7IH0KICAgICAgICByZXR1
cm4gX3A7CiAgICB9CiAgICBmdW5jdGlvbiBidWlsZFBpbm5lZEJsb2NrcyhsaXN0KSB7CiAgICAgICAg
Y29uc3QgdXNlZCA9IG5ldyBTZXQoKTsKICAgICAgICBjb25zdCBvdXQgPSBbXTsKICAgICAgICBmb3Ig
KGNvbnN0IGMgb2YgbGlzdCkgewogICAgICAgICAgICBpZiAodXNlZC5oYXMoK2MuaWQpKSBjb250aW51
ZTsKICAgICAgICAgICAgY29uc3QgZ2lkID0gZmF2R3JvdXBPZihjKTsKICAgICAgICAgICAgaWYgKCFn
aWQpIHsKICAgICAgICAgICAgICAgIHVzZWQuYWRkKCtjLmlkKTsKICAgICAgICAgICAgICAgIG91dC5w
dXNoKHsga2luZDogJ3NpbmdsZScsIGl0ZW1zOiBbY10gfSk7CiAgICAgICAgICAgICAgICBjb250aW51
ZTsKICAgICAgICAgICAgfQogICAgICAgICAgICBjb25zdCBtZW1iZXJzID0gbGlzdC5maWx0ZXIoeCA9
PiBmYXZHcm91cE9mKHgpID09PSBnaWQpOwogICAgICAgICAgICBtZW1iZXJzLmZvckVhY2gobSA9PiB1
c2VkLmFkZCgrbS5pZCkpOwogICAgICAgICAgICBpZiAobWVtYmVycy5sZW5ndGggPCAyKQogICAgICAg
ICAgICAgICAgb3V0LnB1c2goeyBraW5kOiAnc2luZ2xlJywgaXRlbXM6IFttZW1iZXJzWzBdIHx8IGNd
IH0pOwogICAgICAgICAgICBlbHNlCiAgICAgICAgICAgICAgICBvdXQucHVzaCh7IGtpbmQ6ICdncm91
cCcsIGdpZCwgaXRlbXM6IG1lbWJlcnMgfSk7CiAgICAgICAgfQogICAgICAgIHJldHVybiBvdXQ7CiAg
ICB9CiAgICBmdW5jdGlvbiBfX3ByZXBQYXN0ZSgpIHsKICAgICAgICB0cnkgewogICAgICAgICAgICBj
b25zdCBzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaCcpOwogICAgICAgICAgICBpZiAo
cyAmJiBkb2N1bWVudC5hY3RpdmVFbGVtZW50ID09PSBzKSB0cnkgeyBzLmJsdXIoKTsgfSBjYXRjaCB7
fQogICAgICAgICAgICBpZiAod2luZG93LmdldFNlbGVjdGlvbikgd2luZG93LmdldFNlbGVjdGlvbigp
LnJlbW92ZUFsbFJhbmdlcygpOwogICAgICAgIH0gY2F0Y2gge30KICAgIH0KICAgIGZ1bmN0aW9uIHBh
c3RlT25lKGMpIHsKICAgICAgICBfX3ByZXBQYXN0ZSgpOwogICAgICAgIHNlbGVjdGVkSWQgPSBjLmlk
OwogICAgICAgIGlmIChtdWx0aUlkcy5sZW5ndGgpIGNsZWFyTXVsdGkoKTsKICAgICAgICBzeW5jSXRl
bUhpZ2hsaWdodCgpOwogICAgICAgIG1hcmtQYXN0ZWRMb2NhbChjLmlkKTsKICAgICAgICBhaGsoJ3Bh
c3RlJywgU3RyaW5nKGMuaWQpKTsKICAgIH0KICAgIGZ1bmN0aW9uIGlzSXRlbUNocm9tZVRhcmdldCh0
KSB7CiAgICAgICAgcmV0dXJuICEhKHQgJiYgdC5jbG9zZXN0ICYmIHQuY2xvc2VzdCgnLmktZXhwYW5k
LWJ0biwgLmktc3JjLWljbywgLm1nLXNyYywgLmZkLWJ0biwgLmZkLXBhdGgsIGJ1dHRvbiwgYSwgaW5w
dXQnKSk7CiAgICB9CiAgICBmdW5jdGlvbiBiZWdpblBhc3RlRnJvbUl0ZW0oZSwgYykgewogICAgICAg
IGlmIChlLmJ1dHRvbiAhPSBudWxsICYmIGUuYnV0dG9uICE9PSAwKSByZXR1cm47CiAgICAgICAgaWYg
KGlzSXRlbUNocm9tZVRhcmdldChlLnRhcmdldCkpIHJldHVybjsKICAgICAgICBpZiAoaGFuZGxlSXRl
bUNsaWNrKGUsIGMpKQogICAgICAgICAgICByZXR1cm47CiAgICAgICAgX19wcmVwUGFzdGUoKTsKICAg
ICAgICBzZWxlY3RlZElkID0gYy5pZDsKICAgICAgICByYW5nZUFuY2hvcklkID0gYy5pZDsKICAgICAg
ICBpZiAobXVsdGlJZHMubGVuZ3RoID4gMCAmJiBtdWx0aUlkcy5pbmNsdWRlcygrYy5pZCkpIHsKICAg
ICAgICAgICAgY29uc3QgaWRzID0gbXVsdGlJZHMuc2xpY2UoKTsKICAgICAgICAgICAgY2xlYXJNdWx0
aSgpOwogICAgICAgICAgICBtYXJrUGFzdGVkTG9jYWwoaWRzKTsKICAgICAgICAgICAgaWYgKGlkcy5s
ZW5ndGggPiAxKSBhaGsoJ3Bhc3RlTWFueScsIGlkcy5qb2luKCcsJykpOwogICAgICAgICAgICBlbHNl
IGFoaygncGFzdGUnLCBTdHJpbmcoaWRzWzBdKSk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9
CiAgICAgICAgaWYgKG11bHRpSWRzLmxlbmd0aCkgY2xlYXJNdWx0aSgpOwogICAgICAgIHN5bmNJdGVt
SGlnaGxpZ2h0KCk7CiAgICAgICAgbWFya1Bhc3RlZExvY2FsKGMuaWQpOwogICAgICAgIGFoaygncGFz
dGUnLCBTdHJpbmcoYy5pZCkpOwogICAgfQogICAgZnVuY3Rpb24gbWFrZUdyb3VwSXRlbShpdGVtcywg
aWR4KSB7CiAgICAgICAgY29uc3QgZWwgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAg
ICAgICBlbC5jbGFzc05hbWUgPSAnaXRtIGl0LWdyb3VwJwogICAgICAgICAgICArIChpdGVtcy5zb21l
KGMgPT4gK2MuaWQgPT09ICtzZWxlY3RlZElkKSA/ICcgc2VsJyA6ICcnKQogICAgICAgICAgICArIChp
dGVtcy5zb21lKGMgPT4gbXVsdGlJZHMuaW5jbHVkZXMoK2MuaWQpKSA/ICcgbXVsdGknIDogJycpOwog
ICAgICAgIGVsLmRhdGFzZXQuZ3JvdXAgPSBmYXZHcm91cE9mKGl0ZW1zWzBdKSB8fCAnJzsKICAgICAg
ICBlbC5kYXRhc2V0LmlkID0gaXRlbXNbMF0uaWQ7CgogICAgICAgIGNvbnN0IGhlYWQgPSBkb2N1bWVu
dC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICBoZWFkLmNsYXNzTmFtZSA9ICdtZy1oZWFkJzsK
ICAgICAgICBoZWFkLmlubmVySFRNTCA9ICc8c3BhbiBjbGFzcz0ibWctdGFnIj7lkIjlubY8L3NwYW4+
PHNwYW4+JyArIGl0ZW1zLmxlbmd0aCArICcg5p2hIMK3IOeCueWHu+WNleadoeeymOi0tDwvc3Bhbj4n
OwogICAgICAgIGVsLmFwcGVuZENoaWxkKGhlYWQpOwoKICAgICAgICBpdGVtcy5mb3JFYWNoKGMgPT4g
ewogICAgICAgICAgICBjb25zdCByb3cgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAg
ICAgICAgICAgcm93LmNsYXNzTmFtZSA9ICdtZy1yb3cnCiAgICAgICAgICAgICAgICArICgrc2VsZWN0
ZWRJZCA9PT0gK2MuaWQgPyAnIHNlbCcgOiAnJykKICAgICAgICAgICAgICAgICsgKG11bHRpSWRzLmlu
Y2x1ZGVzKCtjLmlkKSA/ICcgbXVsdGknIDogJycpOwogICAgICAgICAgICByb3cuZGF0YXNldC5pZCA9
IGMuaWQ7CgogICAgICAgICAgICBjb25zdCB0b3AgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYn
KTsKICAgICAgICAgICAgdG9wLmNsYXNzTmFtZSA9ICdtZy1yb3ctdG9wJzsKICAgICAgICAgICAgY29u
c3QgbWFpbiA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBtYWluLmNs
YXNzTmFtZSA9ICdtZy1yb3ctbWFpbic7CgogICAgICAgICAgICBjb25zdCB0aXRsZSA9IFN0cmluZyhj
LmZhdlRpdGxlIHx8ICcnKS50cmltKCk7CiAgICAgICAgICAgIGlmICh0aXRsZSkgewogICAgICAgICAg
ICAgICAgY29uc3QgdCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICAg
ICAgdC5jbGFzc05hbWUgPSAnbWctdGl0bGUnOwogICAgICAgICAgICAgICAgc2V0SGxUZXh0KHQsIHRp
dGxlKTsKICAgICAgICAgICAgICAgIG1haW4uYXBwZW5kQ2hpbGQodCk7CiAgICAgICAgICAgIH0KICAg
ICAgICAgICAgY29uc3QgYm9keSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAg
ICAgICBib2R5LmNsYXNzTmFtZSA9ICdtZy1ib2R5JyArIChub3JtVHlwZShjLnR5cGUpID09PSAnaW1h
Z2UnID8gJyBpbWcnIDogJycpOwogICAgICAgICAgICBzZXRIbFRleHQoYm9keSwgY2xpcENvbnRlbnRQ
cmV2aWV3KGMpKTsKICAgICAgICAgICAgbWFpbi5hcHBlbmRDaGlsZChib2R5KTsKICAgICAgICAgICAg
dG9wLmFwcGVuZENoaWxkKG1haW4pOwoKICAgICAgICAgICAgY29uc3Qgc3JjSWNvID0gU3RyaW5nKGMu
c3JjSWNvbiB8fCAnJyk7CiAgICAgICAgICAgIGNvbnN0IHNyY0V4ZSA9IFN0cmluZyhjLnNyY0V4ZSB8
fCAnJyk7CiAgICAgICAgICAgIGNvbnN0IHNyY1RpdGxlID0gU3RyaW5nKGMuc3JjVGl0bGUgfHwgJycp
OwogICAgICAgICAgICBpZiAoc3JjSWNvKSB7CiAgICAgICAgICAgICAgICBjb25zdCBpbWcgPSBkb2N1
bWVudC5jcmVhdGVFbGVtZW50KCdpbWcnKTsKICAgICAgICAgICAgICAgIGltZy5jbGFzc05hbWUgPSAn
bWctc3JjJzsKICAgICAgICAgICAgICAgIGltZy5zcmMgPSBTVE9SRV9CQVNFICsgZW5jb2RlVVJJQ29t
cG9uZW50KHNyY0ljbyk7CiAgICAgICAgICAgICAgICBpbWcuYWx0ID0gJyc7CiAgICAgICAgICAgICAg
ICBjb25zdCB0aXBUeHQgPSBzcmNUaXRsZSB8fCBzcmNFeGUgfHwgJ+adpea6kCc7CiAgICAgICAgICAg
ICAgICBpbWcudGl0bGUgPSB0aXBUeHQ7CiAgICAgICAgICAgICAgICBpbWcub25jbGljayA9IGUgPT4g
eyBlLnByZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0aW9uKCk7IHNob3dTcmNUaXAoaW1nLCB0
aXBUeHQpOyB9OwogICAgICAgICAgICAgICAgdG9wLmFwcGVuZENoaWxkKGltZyk7CiAgICAgICAgICAg
IH0KICAgICAgICAgICAgcm93LmFwcGVuZENoaWxkKHRvcCk7CgogICAgICAgICAgICByb3cub25wb2lu
dGVyZG93biA9IGUgPT4gewogICAgICAgICAgICAgICAgaWYgKGUuYnV0dG9uICE9PSAwKSByZXR1cm47
CiAgICAgICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAgYmVnaW5Q
YXN0ZUZyb21JdGVtKGUsIGMpOwogICAgICAgICAgICB9OwogICAgICAgICAgICByb3cub25jb250ZXh0
bWVudSA9IGUgPT4gewogICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAg
ICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgIHNlbGVjdGVkSWQgPSBjLmlk
OwogICAgICAgICAgICAgICAgc2hvd0N0eChlLmNsaWVudFgsIGUuY2xpZW50WSwgYyk7CiAgICAgICAg
ICAgIH07CiAgICAgICAgICAgIGVsLmFwcGVuZENoaWxkKHJvdyk7CiAgICAgICAgfSk7CgogICAgICAg
IGVsLm9uY29udGV4dG1lbnUgPSBlID0+IHsKICAgICAgICAgICAgaWYgKGUudGFyZ2V0LmNsb3Nlc3Qo
Jy5tZy1yb3cnKSkgcmV0dXJuOwogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAg
ICAgIHNlbGVjdGVkSWQgPSBpdGVtc1swXS5pZDsKICAgICAgICAgICAgc2hvd0N0eChlLmNsaWVudFgs
IGUuY2xpZW50WSwgaXRlbXNbMF0pOwogICAgICAgIH07CiAgICAgICAgcmV0dXJuIGVsOwogICAgfQoK
ICAgIGZ1bmN0aW9uIG1ha2VJdGVtKGMsIGlkeCkgewogICAgICAgIGNvbnN0IHR5cGUgICA9IG5vcm1U
eXBlKGMudHlwZSk7CiAgICAgICAgY29uc3QgcGlubmVkID0gaXNQaW5uZWQoYyk7CiAgICAgICAgY29u
c3QgcGFzdGVkID0gaXNQYXN0ZWQoYyk7CiAgICAgICAgY29uc3QgZWwgICAgID0gZG9jdW1lbnQuY3Jl
YXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgZWwuY2xhc3NOYW1lICA9ICdpdG0nCiAgICAgICAgICAg
ICsgKHNlbGVjdGVkSWQgPT0gYy5pZCA/ICcgc2VsJyA6ICcnKQogICAgICAgICAgICArIChtdWx0aUlk
cy5pbmNsdWRlcygrYy5pZCkgPyAnIG11bHRpJyA6ICcnKTsKICAgICAgICBlbC5kYXRhc2V0LmlkID0g
Yy5pZDsKCiAgICAgICAgY29uc3QgaWNvICA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwog
ICAgICAgIGNvbnN0IGJvZHkgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICBi
b2R5LmNsYXNzTmFtZSA9ICdpLWJvZHknOwoKICAgICAgICBpZiAodHlwZSA9PT0gJ2ltYWdlJykgewog
ICAgICAgICAgICBpY28uY2xhc3NOYW1lID0gJ2ktaWNvIGltYWdlJzsKICAgICAgICAgICAgaWNvLmlu
bmVySFRNTCA9IFNWRy5pbWFnZTsKICAgICAgICAgICAgYmluZEltZ0hvdmVyUHJldmlldyhpY28sIGMu
aWQsIGMuaW1nRmlsZSk7CiAgICAgICAgICAgIGNvbnN0IHdyYXAgPSBkb2N1bWVudC5jcmVhdGVFbGVt
ZW50KCdkaXYnKTsKICAgICAgICAgICAgd3JhcC5jbGFzc05hbWUgPSAnaS10aHVtYi13cmFwJzsKICAg
ICAgICAgICAgY29uc3QgaW1nICA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2ltZycpOwogICAgICAg
ICAgICBpbWcuY2xhc3NOYW1lID0gJ2ktdGh1bWInOwogICAgICAgICAgICBpbWcuYWx0ID0gJyc7CiAg
ICAgICAgICAgIGNvbnN0IGZpbGUgPSBTdHJpbmcoYy5pbWdGaWxlIHx8ICcnKTsKICAgICAgICAgICAg
bGV0IGZhbGxiYWNrID0gU3RyaW5nKGMuZGF0YSB8fCAnJyk7CiAgICAgICAgICAgIC8vIE5ldmVyIHN5
bmMtY2FsbCBBSEsgdGh1bWIgaGVyZSDigJQgZnJlZXplcyB0YWIgc3dpdGNoZXM7IFB1c2hTdG9yZVRo
dW1icyBmaWxscyBhc3luYwogICAgICAgICAgICBpZiAoIWZhbGxiYWNrLnN0YXJ0c1dpdGgoJ2RhdGE6
JykgJiYgdGh1bWJDYWNoZS5oYXMoU3RyaW5nKGMuaWQpKSkKICAgICAgICAgICAgICAgIGZhbGxiYWNr
ID0gU3RyaW5nKHRodW1iQ2FjaGUuZ2V0KFN0cmluZyhjLmlkKSkpOwogICAgICAgICAgICBpbWcub25s
b2FkID0gKCkgPT4gewogICAgICAgICAgICAgICAgY29uc3QgbXcgPSB3cmFwLmNsaWVudFdpZHRoIHx8
IDMwMDsKICAgICAgICAgICAgICAgIGNvbnN0IG53ID0gaW1nLm5hdHVyYWxXaWR0aCAgfHwgMDsKICAg
ICAgICAgICAgICAgIGNvbnN0IG5oID0gaW1nLm5hdHVyYWxIZWlnaHQgfHwgMDsKICAgICAgICAgICAg
ICAgIGlmICghbncgfHwgIW5oKSByZXR1cm47CiAgICAgICAgICAgICAgICBjb25zdCBzY2FsZSA9IE1h
dGgubWluKDEsIDE4MCAvIG5oLCBtdyAvIG53KTsKICAgICAgICAgICAgICAgIGltZy5zdHlsZS53aWR0
aCAgPSBNYXRoLnJvdW5kKG53ICogc2NhbGUpICsgJ3B4JzsKICAgICAgICAgICAgICAgIGltZy5zdHls
ZS5oZWlnaHQgPSBNYXRoLnJvdW5kKG5oICogc2NhbGUpICsgJ3B4JzsKICAgICAgICAgICAgfTsKICAg
ICAgICAgICAgYmluZFN0b3JlVGh1bWIoaW1nLCBmaWxlLCBjLmlkLCBmYWxsYmFjayk7CiAgICAgICAg
ICAgIHdyYXAuYXBwZW5kQ2hpbGQoaW1nKTsKICAgICAgICAgICAgY29uc3QgbWV0YSA9IGRvY3VtZW50
LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBtZXRhLmNsYXNzTmFtZSA9ICdpLW1ldGEn
OwogICAgICAgICAgICBtZXRhLmlubmVySFRNTCAgPSBgPHNwYW4gY2xhc3M9ImktdGltZSI+JHthZ28o
Yy50aW1lKX08L3NwYW4+JHttZXRhQ2VudGVySHRtbChmYWxzZSl9PGRpdiBjbGFzcz0iaS1tZXRhLXJp
Z2h0Ij4ke2Mud2lkdGggPyBgPHNwYW4gY2xhc3M9ImktdGFnIj4ke2Mud2lkdGh9w5cke2MuaGVpZ2h0
fSBweDwvc3Bhbj5gIDogJyd9PC9kaXY+YDsKICAgICAgICAgICAgYm9keS5hcHBlbmRDaGlsZCh3cmFw
KTsKICAgICAgICAgICAgYm9keS5hcHBlbmRDaGlsZChtZXRhKTsKICAgICAgICB9IGVsc2UgaWYgKHR5
cGUgPT09ICdmaWxlJykgewogICAgICAgICAgICBjb25zdCBmaWxlcyA9IFN0cmluZyhjLnByZXZpZXcg
fHwgYy5kYXRhIHx8ICcnKS5zcGxpdCgvXHI/XG4vKS5maWx0ZXIoQm9vbGVhbik7CiAgICAgICAgICAg
IGNvbnN0IGltYWdlUGF0aHMgPSBmaWxlcy5maWx0ZXIoZiA9PiBpc0ltYWdlRXh0KGZpbGVFeHQoZikp
KTsKICAgICAgICAgICAgY29uc3QgaWMgICAgPSBpY29uRm9yRmlsZXMoZmlsZXMpOwogICAgICAgICAg
ICBpY28uY2xhc3NOYW1lID0gJ2ktaWNvICcgKyBpYy5jbHM7CiAgICAgICAgICAgIGljby5pbm5lckhU
TUwgPSBpYy5zdmc7CgogICAgICAgICAgICBsZXQgdGh1bWJGaWxlID0gU3RyaW5nKGMuaW1nRmlsZSB8
fCAnJyk7CiAgICAgICAgICAgIC8qIGVuc3VyZUZpbGVJbWcgZGVmZXJyZWQ6IGF2b2lkIHN5bmMgZnJl
ZXplIG9uIGZpbGUgdGFiICovCgogICAgICAgICAgICAvLyBJbWFnZS1mb3JtYXQgZmlsZXM6IHNhbWUg
dGh1bWJuYWlsIHJ1bGVzIGFzIHNjcmVlbnNob3QgY2xpcHMKICAgICAgICAgICAgaWYgKHRodW1iRmls
ZSB8fCBpbWFnZVBhdGhzLmxlbmd0aCkgewogICAgICAgICAgICAgICAgY29uc3Qgd3JhcCA9IGRvY3Vt
ZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICAgICAgd3JhcC5jbGFzc05hbWUgPSAn
aS10aHVtYi13cmFwJzsKICAgICAgICAgICAgICAgIGNvbnN0IGltZyAgPSBkb2N1bWVudC5jcmVhdGVF
bGVtZW50KCdpbWcnKTsKICAgICAgICAgICAgICAgIGltZy5jbGFzc05hbWUgPSAnaS10aHVtYic7CiAg
ICAgICAgICAgICAgICBpbWcuYWx0ID0gJyc7CiAgICAgICAgICAgICAgICBpbWcub25sb2FkID0gKCkg
PT4gewogICAgICAgICAgICAgICAgICAgIGNvbnN0IG13ID0gd3JhcC5jbGllbnRXaWR0aCB8fCAzMDA7
CiAgICAgICAgICAgICAgICAgICAgY29uc3QgbncgPSBpbWcubmF0dXJhbFdpZHRoICB8fCAwOwogICAg
ICAgICAgICAgICAgICAgIGNvbnN0IG5oID0gaW1nLm5hdHVyYWxIZWlnaHQgfHwgMDsKICAgICAgICAg
ICAgICAgICAgICBpZiAoIW53IHx8ICFuaCkgcmV0dXJuOwogICAgICAgICAgICAgICAgICAgIGNvbnN0
IHNjYWxlID0gTWF0aC5taW4oMSwgMTgwIC8gbmgsIG13IC8gbncpOwogICAgICAgICAgICAgICAgICAg
IGltZy5zdHlsZS53aWR0aCAgPSBNYXRoLnJvdW5kKG53ICogc2NhbGUpICsgJ3B4JzsKICAgICAgICAg
ICAgICAgICAgICBpbWcuc3R5bGUuaGVpZ2h0ID0gTWF0aC5yb3VuZChuaCAqIHNjYWxlKSArICdweCc7
CiAgICAgICAgICAgICAgICB9OwogICAgICAgICAgICAvKiBlbnN1cmVGaWxlSW1nIGRlZmVycmVkOiBh
dm9pZCBzeW5jIGZyZWV6ZSBvbiBmaWxlIHRhYiAqLwogICAgICAgICAgICAgICAgYmluZFN0b3JlVGh1
bWIoaW1nLCB0aHVtYkZpbGUsIGMuaWQsICcnKTsKICAgICAgICAgICAgICAgIHdyYXAuYXBwZW5kQ2hp
bGQoaW1nKTsKICAgICAgICAgICAgICAgIGJvZHkuYXBwZW5kQ2hpbGQod3JhcCk7CiAgICAgICAgICAg
IH0KCiAgICAgICAgICAgIGNvbnN0IG5hbWUgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsK
ICAgICAgICAgICAgbmFtZS5jbGFzc05hbWUgID0gJ2ktbmFtZSc7CiAgICAgICAgICAgIHNldEhsVGV4
dChuYW1lLCBmaWxlcy5tYXAoZiA9PiBmLnNwbGl0KC9bXFwvXS8pLnBvcCgpKS5qb2luKCdcbicpIHx8
ICco5paH5Lu2KScpOwoKICAgICAgICAgICAgZWwuX2ZpbGVQYXRocyA9IGZpbGVzOwoKICAgICAgICAg
ICAgY29uc3QgZGV0YWlsID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAg
IGRldGFpbC5jbGFzc05hbWUgPSAnaS1maWxlLWRldGFpbCc7CgogICAgICAgICAgICBjb25zdCBtZXRh
ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIG1ldGEuY2xhc3NOYW1l
ID0gJ2ktbWV0YSc7CiAgICAgICAgICAgIGxldCByaWdodCA9ICcnOwogICAgICAgICAgICByaWdodCAr
PSBgPHNwYW4gY2xhc3M9ImktdGFnIj4ke2MuZmlsZUNvdW50IHx8IGZpbGVzLmxlbmd0aCB8fCAxfSDk
uKrmlofku7Y8L3NwYW4+YDsKICAgICAgICAgICAgaWYgKCh0aHVtYkZpbGUgfHwgaW1hZ2VQYXRocy5s
ZW5ndGgpICYmIGMud2lkdGgpCiAgICAgICAgICAgICAgICByaWdodCArPSBgPHNwYW4gY2xhc3M9Imkt
dGFnIj4ke2Mud2lkdGh9w5cke2MuaGVpZ2h0fSBweDwvc3Bhbj5gOwogICAgICAgICAgICBjb25zdCBl
eHBhbmRIdG1sID0gZXhwYW5kQ2hldnJvbihmYWxzZSk7CiAgICAgICAgICAgIGNvbnN0IGNvbGxhcHNl
SHRtbCA9IGV4cGFuZENoZXZyb24odHJ1ZSk7CiAgICAgICAgICAgIG1ldGEuaW5uZXJIVE1MID0KICAg
ICAgICAgICAgICAgIGA8c3BhbiBjbGFzcz0iaS10aW1lIj4ke2FnbyhjLnRpbWUpfTwvc3Bhbj5gICsK
ICAgICAgICAgICAgICAgIG1ldGFDZW50ZXJIdG1sKHsgb246IHRydWUsIGh0bWw6IGV4cGFuZEh0bWwg
fSkgKwogICAgICAgICAgICAgICAgYDxkaXYgY2xhc3M9ImktbWV0YS1yaWdodCI+JHtyaWdodH08L2Rp
dj5gOwoKICAgICAgICAgICAgY29uc3QgZXhwQnRuID0gbWV0YS5xdWVyeVNlbGVjdG9yKCcuaS1leHBh
bmQtYnRuJyk7CiAgICAgICAgICAgIGxldCBkZXRhaWxCdWlsdCA9IGZhbHNlOwogICAgICAgICAgICBl
eHBCdG4ub25jbGljayA9IGUgPT4gewogICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwog
ICAgICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgIGNvbnN0IG9w
ZW4gPSAhZGV0YWlsLmNsYXNzTGlzdC5jb250YWlucygnb24nKTsKICAgICAgICAgICAgICAgIGlmIChv
cGVuICYmICFkZXRhaWxCdWlsdCkgewogICAgICAgICAgICAgICAgICAgIGNvbnN0IHBhdGhSb3dzID0g
ZWwuX3BhdGhSb3dzIHx8IGNoZWNrRmlsZVBhdGhzKGVsLl9maWxlUGF0aHMgfHwgZmlsZXMpOwogICAg
ICAgICAgICAgICAgICAgIGZpbGxGaWxlRGV0YWlsUGFuZWwoZGV0YWlsLCBwYXRoUm93cyk7CiAgICAg
ICAgICAgICAgICAgICAgZGV0YWlsQnVpbHQgPSB0cnVlOwogICAgICAgICAgICAgICAgfQogICAgICAg
ICAgICAgICAgZGV0YWlsLmNsYXNzTGlzdC50b2dnbGUoJ29uJywgb3Blbik7CiAgICAgICAgICAgICAg
ICBpZiAob3BlbikgewogICAgICAgICAgICAgICAgICAgIGRldGFpbC5zdHlsZS5tYXhIZWlnaHQgPSBs
aXN0RXhwYW5kTWF4UHgoKSArICdweCc7CiAgICAgICAgICAgICAgICAgICAgZGV0YWlsLnN0eWxlLm92
ZXJmbG93ID0gJ2F1dG8nOwogICAgICAgICAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgICAgICAg
ICBkZXRhaWwuc3R5bGUubWF4SGVpZ2h0ID0gJyc7CiAgICAgICAgICAgICAgICAgICAgZGV0YWlsLnN0
eWxlLm92ZXJmbG93ID0gJyc7CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICBleHBCdG4u
aW5uZXJIVE1MID0gb3BlbiA/IGNvbGxhcHNlSHRtbCA6IGV4cGFuZEh0bWw7CiAgICAgICAgICAgIH07
CgogICAgICAgICAgICBib2R5LmFwcGVuZENoaWxkKG5hbWUpOwogICAgICAgICAgICBib2R5LmFwcGVu
ZENoaWxkKGRldGFpbCk7CiAgICAgICAgICAgIGJvZHkuYXBwZW5kQ2hpbGQobWV0YSk7CiAgICAgICAg
fSBlbHNlIHsKICAgICAgICAgICAgY29uc3QgdXNlTSA9IGNsaXBVc2VzTUljb24oYyk7CiAgICAgICAg
ICAgIGljby5jbGFzc05hbWUgPSB1c2VNID8gJ2ktaWNvIG1kJyA6ICdpLWljbyB0ZXh0JzsKICAgICAg
ICAgICAgaWNvLmlubmVySFRNTCA9IHVzZU0gPyAoU1ZHLm1kIHx8IFNWRy50ZXh0KSA6IFNWRy50ZXh0
OwogICAgICAgICAgICAvKiBwbGFpbi1saXN0LXByZXYgKi8KICAgICAgICAgICAgLyogcHJldmlldy1l
bGxpcHNpcyAqLwogICAgICAgICAgICBsZXQgdHh0ICA9IGMucHJldmlldyB8fCBjLmRhdGEgfHwgJyc7
CiAgICAgICAgICAgIHsgY29uc3QgX24gPSBOdW1iZXIoYy5jaGFyQ291bnQpIHx8IDA7IGlmIChfbiA+
IHR4dC5sZW5ndGggJiYgdHh0Lmxlbmd0aCkgdHh0ICs9ICcuLi4nOyB9CiAgICAgICAgICAgIGNvbnN0
IHByZXYgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgcHJldi5jbGFz
c05hbWUgID0gJ2ktcHJldicgKyAoaXNVcmwodHh0KSA/ICcgdXJsJyA6ICcnKTsKICAgICAgICAgICAg
c2V0SGxUZXh0KHByZXYsIHR4dCk7CgogICAgICAgICAgICBjb25zdCBtZXRhID0gZG9jdW1lbnQuY3Jl
YXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIG1ldGEuY2xhc3NOYW1lID0gJ2ktbWV0YSc7Cgog
ICAgICAgICAgICBjb25zdCBjaGFycyA9IE51bWJlcihjLmNoYXJDb3VudCkgfHwgMDsKICAgICAgICAg
ICAgY29uc3QgcmlnaHRIVE1MID0gYDxzcGFuIGNsYXNzPSJpLWNoYXJzIj48c3BhbiBjbGFzcz0ibiI+
JHtjaGFyc308L3NwYW4+IOWtl+espjwvc3Bhbj5gOwoKICAgICAgICAgICAgbWV0YS5pbm5lckhUTUwg
PQogICAgICAgICAgICAgICAgYDxzcGFuIGNsYXNzPSJpLXRpbWUiPiR7YWdvKGMudGltZSl9PC9zcGFu
PmAgKwogICAgICAgICAgICAgICAgbWV0YUNlbnRlckh0bWwoewogICAgICAgICAgICAgICAgICAgIG9u
OiBmYWxzZSwKICAgICAgICAgICAgICAgICAgICBodG1sOiBleHBhbmRDaGV2cm9uKGZhbHNlKQogICAg
ICAgICAgICAgICAgfSkgKwogICAgICAgICAgICAgICAgYDxkaXYgY2xhc3M9ImktbWV0YS1yaWdodCB0
ZXh0LW1ldGEiPiR7cmlnaHRIVE1MfTwvZGl2PmA7CgogICAgICAgICAgICBib2R5LmFwcGVuZENoaWxk
KHByZXYpOwogICAgICAgICAgICBib2R5LmFwcGVuZENoaWxkKG1ldGEpOwoKICAgICAgICAgICAgY29u
c3QgZXhwQnRuID0gbWV0YS5xdWVyeVNlbGVjdG9yKCcuaS1leHBhbmQtYnRuJyk7CiAgICAgICAgICAg
IGlmIChleHBCdG4pIHsKICAgICAgICAgICAgICAgIGV4cEJ0bi5vbmNsaWNrID0gZSA9PiB7CiAgICAg
ICAgICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgICAgICBjb25z
dCB3aWxsRXhwYW5kID0gIXByZXYuY2xhc3NMaXN0LmNvbnRhaW5zKCdleHBhbmRlZCcpOwogICAgICAg
ICAgICAgICAgICAgIGlmICh3aWxsRXhwYW5kKSB7CiAgICAgICAgICAgICAgICAgICAgICAgIGFwcGx5
RXhwYW5kZWRQcmV2aWV3KHByZXYsIHR4dCk7CiAgICAgICAgICAgICAgICAgICAgICAgIGV4cEJ0bi5p
bm5lckhUTUwgPSBleHBhbmRDaGV2cm9uKHRydWUpOwogICAgICAgICAgICAgICAgICAgICAgICB0cnkg
eyBlbC5zY3JvbGxJbnRvVmlldyh7IGJsb2NrOiAnbmVhcmVzdCcgfSk7IH0gY2F0Y2gge30KICAgICAg
ICAgICAgICAgICAgICB9IGVsc2UgewogICAgICAgICAgICAgICAgICAgICAgICBjb2xsYXBzZVByZXZp
ZXcocHJldiwgdHh0KTsKICAgICAgICAgICAgICAgICAgICAgICAgZXhwQnRuLmlubmVySFRNTCA9IGV4
cGFuZENoZXZyb24oZmFsc2UpOwogICAgICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgIH07
CiAgICAgICAgICAgICAgICBjb25zdCBjaGVja092ZXJmbG93ID0gKCkgPT4gewogICAgICAgICAgICAg
ICAgICAgIGNvbnN0IHBsYWluTGVuID0gU3RyaW5nKGMucHJldmlldyB8fCBjLmRhdGEgfHwgJycpLmxl
bmd0aDsKICAgICAgICAgICAgICAgICAgICBjb25zdCBmdWxsTiA9IE51bWJlcihjLmNoYXJDb3VudCkg
fHwgMDsKICAgICAgICAgICAgICAgICAgICBjb25zdCB0cnVuYyA9IGZ1bGxOID4gcGxhaW5MZW47CiAg
ICAgICAgICAgICAgICAgICAgaWYgKHByZXYuc2Nyb2xsSGVpZ2h0ID4gcHJldi5jbGllbnRIZWlnaHQg
KyAyIHx8IHRydW5jKQogICAgICAgICAgICAgICAgICAgICAgICBleHBCdG4uY2xhc3NMaXN0LmFkZCgn
b24nKTsKICAgICAgICAgICAgICAgICAgICBlbHNlCiAgICAgICAgICAgICAgICAgICAgICAgIGV4cEJ0
bi5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgICAgICAgICAgfTsKICAgICAgICAgICAgICAg
IHJlcXVlc3RBbmltYXRpb25GcmFtZShjaGVja092ZXJmbG93KTsKICAgICAgICAgICAgICAgIHNldFRp
bWVvdXQoY2hlY2tPdmVyZmxvdywgODApOwogICAgICAgICAgICB9CiAgICAgICAgfQoKICAgICAgICBj
b25zdCBmYXZUID0gU3RyaW5nKGMuZmF2VGl0bGUgfHwgJycpLnRyaW0oKTsKICAgICAgICBpZiAoZmF2
VCkgewogICAgICAgICAgICBjb25zdCBmdCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwog
ICAgICAgICAgICBmdC5jbGFzc05hbWUgPSAnaS1mYXYtdGl0bGUnOwogICAgICAgICAgICBzZXRIbFRl
eHQoZnQsIGZhdlQpOwogICAgICAgICAgICBib2R5Lmluc2VydEJlZm9yZShmdCwgYm9keS5maXJzdENo
aWxkKTsKICAgICAgICB9CgogICAgICAgIGlmIChwYXN0ZWQpIHsKICAgICAgICAgICAgY29uc3QgYmFk
Z2UgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdzcGFuJyk7CiAgICAgICAgICAgIGJhZGdlLmNsYXNz
TmFtZSA9ICdpLXVzZWQnOwogICAgICAgICAgICBiYWRnZS50aXRsZSA9ICflt7LnspjotLQnOwogICAg
ICAgICAgICBiYWRnZS5pbm5lckhUTUwgPSBgPHN2ZyB2aWV3Qm94PSIwIDAgMTYgMTYiIGZpbGw9Im5v
bmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIuNCIgc3Ryb2tlLWxpbmVjYXA9
InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIj48cG9seWxpbmUgcG9pbnRzPSIzLjUgOC41IDYu
NSAxMS41IDEyLjUgNC41Ii8+PC9zdmc+YDsKICAgICAgICAgICAgaWNvLmFwcGVuZENoaWxkKGJhZGdl
KTsKICAgICAgICB9CgogICAgICAgIGNvbnN0IG51bSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2Rp
dicpOwogICAgICAgIG51bS5jbGFzc05hbWUgPSAnaS1udW0nOwogICAgICAgIGNvbnN0IG51bVR4dCA9
IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ3NwYW4nKTsKICAgICAgICBudW1UeHQudGV4dENvbnRlbnQg
PSBpZHg7CiAgICAgICAgbnVtLmFwcGVuZENoaWxkKG51bVR4dCk7CiAgICAgICAgY29uc3Qgc3JjSWNv
ID0gU3RyaW5nKGMuc3JjSWNvbiB8fCAnJyk7CiAgICAgICAgY29uc3Qgc3JjRXhlID0gU3RyaW5nKGMu
c3JjRXhlIHx8ICcnKTsKICAgICAgICBjb25zdCBzcmNUaXRsZSA9IFN0cmluZyhjLnNyY1RpdGxlIHx8
ICcnKTsKICAgICAgICBpZiAoc3JjSWNvKSB7CiAgICAgICAgICAgIGNvbnN0IGltZyA9IGRvY3VtZW50
LmNyZWF0ZUVsZW1lbnQoJ2ltZycpOwogICAgICAgICAgICBpbWcuY2xhc3NOYW1lID0gJ2ktc3JjLWlj
byc7CiAgICAgICAgICAgIGltZy5zcmMgPSBTVE9SRV9CQVNFICsgZW5jb2RlVVJJQ29tcG9uZW50KHNy
Y0ljbyk7CiAgICAgICAgICAgIGltZy5hbHQgPSAnJzsKICAgICAgICAgICAgY29uc3QgdGlwVHh0ID0g
c3JjVGl0bGUgfHwgc3JjRXhlIHx8ICfmnaXmupAnOwogICAgICAgICAgICBpbWcudGl0bGUgPSB0aXBU
eHQ7CiAgICAgICAgICAgIGltZy5vbmNsaWNrID0gZSA9PiB7IGUucHJldmVudERlZmF1bHQoKTsgZS5z
dG9wUHJvcGFnYXRpb24oKTsgc2hvd1NyY1RpcChpbWcsIHRpcFR4dCk7IH07CiAgICAgICAgICAgIG51
bS5hcHBlbmRDaGlsZChpbWcpOwogICAgICAgIH0KCiAgICAgICAgZWwuYXBwZW5kQ2hpbGQoaWNvKTsK
ICAgICAgICBlbC5hcHBlbmRDaGlsZChib2R5KTsKICAgICAgICBlbC5hcHBlbmRDaGlsZChudW0pOwoK
ICAgICAgICBlbC5vbnBvaW50ZXJkb3duID0gZSA9PiB7CiAgICAgICAgICAgIGJlZ2luUGFzdGVGcm9t
SXRlbShlLCBjKTsKICAgICAgICB9OwogICAgICAgIGVsLm9uY29udGV4dG1lbnUgPSBlID0+IHsKICAg
ICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICBzZWxlY3RlZElkID0gYy5pZDsK
ICAgICAgICAgICAgc2hvd0N0eChlLmNsaWVudFgsIGUuY2xpZW50WSwgYyk7CiAgICAgICAgfTsKCiAg
ICAgICAgcmV0dXJuIGVsOwogICAgfQoKICAgIGNvbnN0IHBhdGhUaXBFbCA9IGRvY3VtZW50LmdldEVs
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
ICAgICAgfSk7CiAgICAgICAgfSwgMCk7CiAgICB9CiAgICBmdW5jdGlvbiBmaWxsRmlsZURldGFpbFBh
bmVsKGNvbnRhaW5lciwgcm93cykgewogICAgICAgIGNvbnRhaW5lci5pbm5lckhUTUwgPSAnJzsKICAg
ICAgICBpZiAoIXJvd3MubGVuZ3RoKSB7CiAgICAgICAgICAgIGNvbnN0IGVtcHR5ID0gZG9jdW1lbnQu
Y3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIGVtcHR5LmNsYXNzTmFtZSA9ICdmZC1wYXRo
JzsKICAgICAgICAgICAgZW1wdHkudGV4dENvbnRlbnQgPSAn5peg6Lev5b6EJzsKICAgICAgICAgICAg
Y29udGFpbmVyLmFwcGVuZENoaWxkKGVtcHR5KTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0K
ICAgICAgICByb3dzLmZvckVhY2gociA9PiB7CiAgICAgICAgICAgIGNvbnN0IHBhdGggPSBTdHJpbmco
ci5wYXRoIHx8ICcnKTsKICAgICAgICAgICAgY29uc3QgbWlzc2luZyA9IHIuZXhpc3RzID09PSBmYWxz
ZTsKICAgICAgICAgICAgY29uc3QgYmxvY2sgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsK
ICAgICAgICAgICAgYmxvY2suY2xhc3NOYW1lID0gJ2ZkLWJsb2NrJzsKCiAgICAgICAgICAgIGNvbnN0
IHBhdGhFbCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBwYXRoRWwu
Y2xhc3NOYW1lID0gJ2ZkLXBhdGgnICsgKG1pc3NpbmcgPyAnIGRlYWQnIDogJyBsaXZlJyk7CiAgICAg
ICAgICAgIHBhdGhFbC50ZXh0Q29udGVudCA9IHBhdGggfHwgJyjnqbrot6/lvoQpJzsKICAgICAgICAg
ICAgaWYgKCFtaXNzaW5nKSB7CiAgICAgICAgICAgICAgICBwYXRoRWwub25jbGljayA9IGUgPT4gewog
ICAgICAgICAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgICAgICAgICBl
LnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAgICAgIGFoaygnb3BlblBhdGgnLCBwYXRo
KTsKICAgICAgICAgICAgICAgIH07CiAgICAgICAgICAgIH0KICAgICAgICAgICAgYmxvY2suYXBwZW5k
Q2hpbGQocGF0aEVsKTsKCiAgICAgICAgICAgIGNvbnN0IGFjdGlvbnMgPSBkb2N1bWVudC5jcmVhdGVF
bGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgYWN0aW9ucy5jbGFzc05hbWUgPSAnZmQtYWN0aW9ucyc7
CgogICAgICAgICAgICBjb25zdCBjb3B5QnRuID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnYnV0dG9u
Jyk7CiAgICAgICAgICAgIGNvcHlCdG4udHlwZSA9ICdidXR0b24nOwogICAgICAgICAgICBjb3B5QnRu
LmNsYXNzTmFtZSA9ICdmZC1idG4nOwogICAgICAgICAgICBjb3B5QnRuLmlubmVySFRNTCA9ICc8c3Bh
biBjbGFzcz0iZmQtaWNvIj7wn5SXPC9zcGFuPjxzcGFuIGNsYXNzPSJmZC10eHQiPuWkjeWItui3r+W+
hDwvc3Bhbj4nOwogICAgICAgICAgICBjb3B5QnRuLm9uY2xpY2sgPSBlID0+IHsKICAgICAgICAgICAg
ICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7
CiAgICAgICAgICAgICAgICBhaGsoJ2NvcHlQYXRoJywgcGF0aCk7CiAgICAgICAgICAgICAgICBjb3B5
QnRuLnF1ZXJ5U2VsZWN0b3IoJy5mZC10eHQnKS50ZXh0Q29udGVudCA9ICflt7LlpI3liLYnOwogICAg
ICAgICAgICAgICAgY29weUJ0bi5jbGFzc0xpc3QuYWRkKCdvaycpOwogICAgICAgICAgICAgICAgc2V0
VGltZW91dCgoKSA9PiB7CiAgICAgICAgICAgICAgICAgICAgY29weUJ0bi5xdWVyeVNlbGVjdG9yKCcu
ZmQtdHh0JykudGV4dENvbnRlbnQgPSAn5aSN5Yi26Lev5b6EJzsKICAgICAgICAgICAgICAgICAgICBj
b3B5QnRuLmNsYXNzTGlzdC5yZW1vdmUoJ29rJyk7CiAgICAgICAgICAgICAgICB9LCAxMjAwKTsKICAg
ICAgICAgICAgfTsKICAgICAgICAgICAgYWN0aW9ucy5hcHBlbmRDaGlsZChjb3B5QnRuKTsKCiAgICAg
ICAgICAgIGNvbnN0IGZvbGRlckJ0biA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2J1dHRvbicpOwog
ICAgICAgICAgICBmb2xkZXJCdG4udHlwZSA9ICdidXR0b24nOwogICAgICAgICAgICBmb2xkZXJCdG4u
Y2xhc3NOYW1lID0gJ2ZkLWJ0bic7CiAgICAgICAgICAgIGZvbGRlckJ0bi5pbm5lckhUTUwgPSAnPHNw
YW4gY2xhc3M9ImZkLWljbyI+8J+Tgjwvc3Bhbj48c3BhbiBjbGFzcz0iZmQtdHh0Ij7miZPlvIDmiYDl
nKjmlofku7blpLk8L3NwYW4+JzsKICAgICAgICAgICAgZm9sZGVyQnRuLm9uY2xpY2sgPSBlID0+IHsK
ICAgICAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgICAgIGUuc3RvcFBy
b3BhZ2F0aW9uKCk7CiAgICAgICAgICAgICAgICBhaGsoJ29wZW5Gb2xkZXInLCBwYXRoKTsKICAgICAg
ICAgICAgfTsKICAgICAgICAgICAgYWN0aW9ucy5hcHBlbmRDaGlsZChmb2xkZXJCdG4pOwoKICAgICAg
ICAgICAgYmxvY2suYXBwZW5kQ2hpbGQoYWN0aW9ucyk7CiAgICAgICAgICAgIGNvbnRhaW5lci5hcHBl
bmRDaGlsZChibG9jayk7CiAgICAgICAgfSk7CiAgICB9CgogICAgY29uc3QgY3R4RWwgPSBkb2N1bWVu
dC5nZXRFbGVtZW50QnlJZCgnY3R4Jyk7CiAgICBmdW5jdGlvbiBzaG93Q3R4KHgsIHksIGMpIHsKICAg
ICAgICBjdHhDbGlwID0gYzsKICAgICAgICBzZWxlY3RlZElkID0gYy5pZDsKICAgICAgICByYW5nZUFu
Y2hvcklkID0gYy5pZDsKICAgICAgICByYW5nZUFuY2hvckNsaWNrZWQgPSB0cnVlOwogICAgICAgIGNv
bnN0IGNsZWFyQnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtY2xlYXItcGFzdGVkJyk7CiAg
ICAgICAgaWYgKGNsZWFyQnRuKSBjbGVhckJ0bi5zdHlsZS5kaXNwbGF5ID0gaXNQYXN0ZWQoYykgPyAn
JyA6ICdub25lJzsKCiAgICAgICAgY29uc3QgcGluQnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQo
J2MtcGluJyk7CiAgICAgICAgaWYgKHBpbkJ0bikgewogICAgICAgICAgICBjb25zdCBvbiA9IGlzUGlu
bmVkKGMpOwogICAgICAgICAgICBwaW5CdG4uaW5uZXJIVE1MID0gb24KICAgICAgICAgICAgICAgID8g
JzxzcGFuIGNsYXNzPSJjLWljbyI+4piFPC9zcGFuPuWPlua2iOaUtuiXjycKICAgICAgICAgICAgICAg
IDogJzxzcGFuIGNsYXNzPSJjLWljbyI+4piFPC9zcGFuPuaUtuiXjyc7CiAgICAgICAgfQogICAgICAg
IGNvbnN0IHRpdGxlQnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtdGl0bGUnKTsKICAgICAg
ICBpZiAodGl0bGVCdG4pIHsKICAgICAgICAgICAgY29uc3Qgc2hvd1RpdGxlID0gaXNQaW5uZWQoYykg
fHwgY3VyVGFiID09PSAncGlubmVkJzsKICAgICAgICAgICAgdGl0bGVCdG4uc3R5bGUuZGlzcGxheSA9
IHNob3dUaXRsZSA/ICcnIDogJ25vbmUnOwogICAgICAgICAgICBpZiAoc2hvd1RpdGxlKQogICAgICAg
ICAgICAgICAgdGl0bGVCdG4uaW5uZXJIVE1MID0gKFN0cmluZyhjLmZhdlRpdGxlIHx8ICcnKS50cmlt
KCkgPyAnPHNwYW4gY2xhc3M9ImMtaWNvIj7inI48L3NwYW4+57yW6L6R5qCH6aKYJyA6ICc8c3BhbiBj
bGFzcz0iYy1pY28iPuKcjjwvc3Bhbj7orr7nva7moIfpopgnKTsKICAgICAgICB9CiAgICAgICAgY29u
c3QgbWVyZ2VCdG4gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYy1tZXJnZScpOwogICAgICAgIGNv
bnN0IHVubWVyZ2VCdG4gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYy11bm1lcmdlJyk7CiAgICAg
ICAgY29uc3Qgb25QaW5uZWQgPSBjdXJUYWIgPT09ICdwaW5uZWQnOwogICAgICAgIGlmIChtZXJnZUJ0
bikKICAgICAgICAgICAgbWVyZ2VCdG4uc3R5bGUuZGlzcGxheSA9IChvblBpbm5lZCAmJiBtdWx0aUlk
cy5sZW5ndGggPj0gMikgPyAnJyA6ICdub25lJzsKICAgICAgICBpZiAodW5tZXJnZUJ0bikKICAgICAg
ICAgICAgdW5tZXJnZUJ0bi5zdHlsZS5kaXNwbGF5ID0gKG9uUGlubmVkICYmIGZhdkdyb3VwT2YoYykp
ID8gJycgOiAnbm9uZSc7CiAgICAgICAgY3R4RWwuY2xhc3NMaXN0LmFkZCgnb24nKTsKICAgICAgICBj
dHhFbC5zdHlsZS5sZWZ0ID0geCArICdweCc7CiAgICAgICAgY3R4RWwuc3R5bGUudG9wICA9IHkgKyAn
cHgnOwogICAgICAgIHJlcXVlc3RBbmltYXRpb25GcmFtZSgoKSA9PiB7CiAgICAgICAgICAgIGNvbnN0
IHIgPSBjdHhFbC5nZXRCb3VuZGluZ0NsaWVudFJlY3QoKTsKICAgICAgICAgICAgaWYgKHIucmlnaHQg
ID4gaW5uZXJXaWR0aCkgIGN0eEVsLnN0eWxlLmxlZnQgPSAoeCAtIHIud2lkdGgpICArICdweCc7CiAg
ICAgICAgICAgIGlmIChyLmJvdHRvbSA+IGlubmVySGVpZ2h0KSBjdHhFbC5zdHlsZS50b3AgID0gKHkg
LSByLmhlaWdodCkgKyAncHgnOwogICAgICAgIH0pOwogICAgfQogICAgZnVuY3Rpb24gaGlkZUN0eCgp
IHsgY3R4RWwuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsgY3R4Q2xpcCA9IG51bGw7IH0KICAgIHdpbmRv
dy5fX2hpZGVDdHggPSBoaWRlQ3R4OwoKICAgIGZ1bmN0aW9uIGRpc21pc3NDdHhVbmxlc3NJbnNpZGUo
ZSkgewogICAgICAgIGlmICghY3R4RWwuY2xhc3NMaXN0LmNvbnRhaW5zKCdvbicpKSByZXR1cm47CiAg
ICAgICAgaWYgKGUudGFyZ2V0LmNsb3Nlc3QoJyNjdHgnKSkgcmV0dXJuOwogICAgICAgIGhpZGVDdHgo
KTsKICAgIH0KICAgIGRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIoJ21vdXNlZG93bicsIGRpc21pc3ND
dHhVbmxlc3NJbnNpZGUsIHRydWUpOwogICAgZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2sn
LCBkaXNtaXNzQ3R4VW5sZXNzSW5zaWRlLCB0cnVlKTsKICAgIGxpc3RFbC5hZGRFdmVudExpc3RlbmVy
KCdzY3JvbGwnLCBoaWRlQ3R4LCB7IHBhc3NpdmU6IHRydWUgfSk7CiAgICBkb2N1bWVudC5hZGRFdmVu
dExpc3RlbmVyKCdrZXlkb3duJywgZSA9PiB7CiAgICAgICAgLy8gRXNjOiBhbHdheXMgY2xvc2UgcGFu
ZWwgKHNlYXJjaCBvciBub3QpOyBwaW4ga2VlcHMgcGFuZWwKICAgICAgICBpZiAoZS5rZXkgPT09ICdF
c2NhcGUnKSB7CiAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgaGlkZUN0
eCgpOwogICAgICAgICAgICBjb25zdCB0ZCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0aXRsZS1k
bGcnKTsKICAgICAgICAgICAgaWYgKHRkICYmIHRkLmNsYXNzTGlzdC5jb250YWlucygnb24nKSkgewog
ICAgICAgICAgICAgICAgdHJ5IHsgY2xvc2VUaXRsZURsZygpOyB9IGNhdGNoIHsgdGQuY2xhc3NMaXN0
LnJlbW92ZSgnb24nKTsgfQogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICB9CiAgICAg
ICAgICAgIGlmIChjbHJEbGcuY2xhc3NMaXN0LmNvbnRhaW5zKCdvbicpKSB7CiAgICAgICAgICAgICAg
ICBjbG9zZUNsZWFyRGxnKCk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAg
ICAgICAgICAgaWYgKCFwaW5uZWRVSSkgYWhrKCdoaWRlJyk7CiAgICAgICAgICAgIHJldHVybjsKICAg
ICAgICB9CiAgICAgICAgLy8gV2hpbGUgdHlwaW5nIGluIHNlYXJjaDogQ3RybCtJL0sgYW5kIGFycm93
cyBtb3ZlIGxpc3QsIGRvbid0IGxlYXZlIHRoZSBib3gKICAgICAgICBpZiAoZG9jdW1lbnQuYWN0aXZl
RWxlbWVudD8uaWQgPT09ICdzZWFyY2gnKSB7CiAgICAgICAgICAgIGlmICgoZS5jdHJsS2V5IHx8IGUu
bWV0YUtleSkgJiYgKGUua2V5ID09PSAnaScgfHwgZS5rZXkgPT09ICdJJykpIHsKICAgICAgICAgICAg
ICAgIGUucHJldmVudERlZmF1bHQoKTsgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAg
IHdpbmRvdy5fX25hdiAmJiB3aW5kb3cuX19uYXYoJ3VwJyk7CiAgICAgICAgICAgICAgICByZXR1cm47
CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKChlLmN0cmxLZXkgfHwgZS5tZXRhS2V5KSAmJiAo
ZS5rZXkgPT09ICdrJyB8fCBlLmtleSA9PT0gJ0snKSkgewogICAgICAgICAgICAgICAgZS5wcmV2ZW50
RGVmYXVsdCgpOyBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAgd2luZG93Ll9fbmF2
ICYmIHdpbmRvdy5fX25hdignZG93bicpOwogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAg
ICB9CiAgICAgICAgICAgIGlmIChlLmtleSA9PT0gJ0Fycm93RG93bicpIHsKICAgICAgICAgICAgICAg
IGUucHJldmVudERlZmF1bHQoKTsgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgIHdp
bmRvdy5fX25hdiAmJiB3aW5kb3cuX19uYXYoJ2Rvd24nKTsKICAgICAgICAgICAgICAgIHJldHVybjsK
ICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAoZS5rZXkgPT09ICdBcnJvd1VwJykgewogICAgICAg
ICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOyBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAg
ICAgICAgd2luZG93Ll9fbmF2ICYmIHdpbmRvdy5fX25hdigndXAnKTsKICAgICAgICAgICAgICAgIHJl
dHVybjsKICAgICAgICAgICAgfQogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGNv
bnN0IHZpcyA9ICh0eXBlb2YgbmF2TGlzdCA9PT0gJ2Z1bmN0aW9uJyA/IG5hdkxpc3QoKSA6IHZpc2li
bGVMaXN0KCkpOwogICAgICAgIGlmICghdmlzLmxlbmd0aCkgcmV0dXJuOwogICAgICAgIGxldCBpZHgg
PSBzZWxlY3RlZEluZGV4KCk7CiAgICAgICAgaWYgKGlkeCA8IDApIGlkeCA9IDA7CiAgICAgICAgaWYg
ICAgICAoZS5rZXkgPT09ICdBcnJvd0Rvd24nKSB7IGUucHJldmVudERlZmF1bHQoKTsgZS5zdG9wUHJv
cGFnYXRpb24oKTsgc2VsZWN0QnlJbmRleChpZHggKyAxKTsgfQogICAgICAgIGVsc2UgaWYgKGUua2V5
ID09PSAnQXJyb3dVcCcpICAgeyBlLnByZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0aW9uKCk7
IHNlbGVjdEJ5SW5kZXgoaWR4IC0gMSk7IH0KICAgICAgICBlbHNlIGlmIChlLmtleSA9PT0gJ0VudGVy
JykgewogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgIC8vIOWbuuWumuaX
tuWbnui9puS4jeeymOi0tO+8jOWPqueCueadoeebrueymOi0tAogICAgICAgICAgICBpZiAocGlubmVk
VUkpIHJldHVybjsKICAgICAgICAgICAgaWYgKG11bHRpSWRzLmxlbmd0aCA+IDEpIHsKICAgICAgICAg
ICAgICAgIGNvbnN0IGlkcyA9IG11bHRpSWRzLnNsaWNlKCk7CiAgICAgICAgICAgICAgICBjbGVhck11
bHRpKCk7CiAgICAgICAgICAgICAgICBtYXJrUGFzdGVkTG9jYWwoaWRzKTsKICAgICAgICAgICAgICAg
IGFoaygncGFzdGVNYW55JywgaWRzLmpvaW4oJywnKSk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAg
ICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKG11bHRpSWRzLmxlbmd0aCA9PT0gMSkgewogICAgICAg
ICAgICAgICAgY29uc3QgaWQgPSBtdWx0aUlkc1swXTsKICAgICAgICAgICAgICAgIGNsZWFyTXVsdGko
KTsKICAgICAgICAgICAgICAgIG1hcmtQYXN0ZWRMb2NhbChpZCk7CiAgICAgICAgICAgICAgICBhaGso
J3Bhc3RlJywgU3RyaW5nKGlkKSk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0K
ICAgICAgICAgICAgY29uc3QgYyA9IHZpc1tzZWxlY3RlZEluZGV4KCldOwogICAgICAgICAgICBpZiAo
YykgewogICAgICAgICAgICAgICAgbWFya1Bhc3RlZExvY2FsKGMuaWQpOwogICAgICAgICAgICAgICAg
YWhrKCdwYXN0ZScsIFN0cmluZyhjLmlkKSk7CiAgICAgICAgICAgIH0KICAgICAgICB9IGVsc2UgaWYg
KC9eWzEtOV0kLy50ZXN0KGUua2V5KSkgewogICAgICAgICAgICBjb25zdCBjID0gdmlzWytlLmtleSAt
IDFdOwogICAgICAgICAgICBpZiAoYykgewogICAgICAgICAgICAgICAgbWFya1Bhc3RlZExvY2FsKGMu
aWQpOwogICAgICAgICAgICAgICAgYWhrKCdwYXN0ZScsIFN0cmluZyhjLmlkKSk7CiAgICAgICAgICAg
IH0KICAgICAgICB9CiAgICB9KTsKCiAgICB3aW5kb3cuX19uYXYgPSBkaXIgPT4gewogICAgICAgIGNv
bnN0IHZpcyA9ICh0eXBlb2YgbmF2TGlzdCA9PT0gJ2Z1bmN0aW9uJyA/IG5hdkxpc3QoKSA6IHZpc2li
bGVMaXN0KCkpOwogICAgICAgIGlmICghdmlzLmxlbmd0aCAmJiBkaXIgIT09ICd0YWInICYmIGRpciAh
PT0gJ3RhYlByZXYnKSByZXR1cm47CiAgICAgICAgbGV0IGlkeCA9IHNlbGVjdGVkSW5kZXgoKTsKICAg
ICAgICBpZiAoaWR4IDwgMCkgaWR4ID0gMDsKICAgICAgICBpZiAoZGlyID09PSAndXAnKSBzZWxlY3RC
eUluZGV4KGlkeCAtIDEpOwogICAgICAgIGVsc2UgaWYgKGRpciA9PT0gJ2Rvd24nKSBzZWxlY3RCeUlu
ZGV4KGlkeCArIDEpOwogICAgICAgIGVsc2UgaWYgKGRpciA9PT0gJ2VudGVyJykgewogICAgICAgICAg
ICBpZiAocGlubmVkVUkpIHJldHVybjsKICAgICAgICAgICAgX19wcmVwUGFzdGUoKTsKICAgICAgICAg
ICAgaWYgKG11bHRpSWRzLmxlbmd0aCA+IDEpIHsKICAgICAgICAgICAgICAgIGNvbnN0IGlkcyA9IG11
bHRpSWRzLnNsaWNlKCk7CiAgICAgICAgICAgICAgICBjbGVhck11bHRpKCk7CiAgICAgICAgICAgICAg
ICBtYXJrUGFzdGVkTG9jYWwoaWRzKTsKICAgICAgICAgICAgICAgIGFoaygncGFzdGVNYW55JywgaWRz
LmpvaW4oJywnKSk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAg
ICAgaWYgKG11bHRpSWRzLmxlbmd0aCA9PT0gMSkgewogICAgICAgICAgICAgICAgY29uc3QgaWQgPSBt
dWx0aUlkc1swXTsKICAgICAgICAgICAgICAgIGNsZWFyTXVsdGkoKTsKICAgICAgICAgICAgICAgIG1h
cmtQYXN0ZWRMb2NhbChpZCk7CiAgICAgICAgICAgICAgICBhaGsoJ3Bhc3RlJywgU3RyaW5nKGlkKSk7
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
cmV0dXJuOwogICAgICAgIH0KICAgICAgICAvLyDlm7rlrprml7blm57ovabkuI3nspjotLQKICAgICAg
ICBpZiAocGlubmVkVUkpIHJldHVybjsKICAgICAgICAvLyBUeXBpbmcgaW4gc2VhcmNoOiBFbnRlciBz
aG91bGQgcGFzdGUgc2VsZWN0ZWQgaXRlbQogICAgICAgIGlmIChkb2N1bWVudC5hY3RpdmVFbGVtZW50
Py5pZCA9PT0gJ3NlYXJjaCcpIHsKICAgICAgICAgICAgd2luZG93Ll9fbmF2ICYmIHdpbmRvdy5fX25h
dignZW50ZXInKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICB3aW5kb3cuX19u
YXYgJiYgd2luZG93Ll9fbmF2KCdlbnRlcicpOwogICAgfTsKCiAgICB3aW5kb3cuX19jeWNsZVRhYiA9
IGRpciA9PiB7CiAgICAgICAgY29uc3QgaSA9IE1hdGgubWF4KDAsIFRBQl9PUkRFUi5pbmRleE9mKGN1
clRhYikpOwogICAgICAgIGNvbnN0IG5leHQgPSBUQUJfT1JERVJbKGkgKyAoZGlyIHwgMCkgKyBUQUJf
T1JERVIubGVuZ3RoICogMTApICUgVEFCX09SREVSLmxlbmd0aF07CiAgICAgICAgc2V0VGFiKG5leHQp
OwogICAgfTsKICAgIHdpbmRvdy5fX29uUGFuZWxTaG93ID0gKGtlZXBTZWFyY2gpID0+IHsKICAgICAg
ICAvLyBEbyBOT1QgZm9jdXMgV2ViVmlldyDigJQga2VlcCBlZGl0b3IgY2FyZXQvZm9jdXMgKEFISyBo
YW5kbGVzIGtleXMgdmlhICNIb3RJZikKICAgICAgICAvLyBXaW4rVjogY29sbGFwc2Ugc2VhcmNoLiA/
PyBzZWFyY2g6IGtlZXAvb3BlbiBzZWFyY2ggYm94LgogICAgICAgIGtlZXBTZWFyY2ggPSAhIWtlZXBT
ZWFyY2g7CiAgICAgICAgdHJ5IHsgaGlkZUN0eCgpOyB9IGNhdGNoIHt9CiAgICAgICAgdHJ5IHsgY2xv
c2VUaXRsZURsZygpOyB9IGNhdGNoIHt9CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgY29uc3Qgd3Jh
cCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gtd3JhcCcpOwogICAgICAgICAgICBjb25z
dCBzcmNoID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaCcpOwogICAgICAgICAgICBjb25z
dCBzY2xyID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaC1jbHInKTsKICAgICAgICAgICAg
aWYgKCFrZWVwU2VhcmNoKSB7CiAgICAgICAgICAgICAgICBpZiAod3JhcCkgd3JhcC5jbGFzc0xpc3Qu
cmVtb3ZlKCdvcGVuJyk7CiAgICAgICAgICAgICAgICBpZiAoc3JjaCkgewogICAgICAgICAgICAgICAg
ICAgIHNyY2gudmFsdWUgPSAnJzsKICAgICAgICAgICAgICAgICAgICBzcmNoLmNsYXNzTGlzdC5yZW1v
dmUoJ2hhcy12YWwnKTsKICAgICAgICAgICAgICAgICAgICB0cnkgeyBzcmNoLmJsdXIoKTsgfSBjYXRj
aCB7fQogICAgICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgaWYgKHNjbHIpIHNjbHIuc3R5bGUu
ZGlzcGxheSA9ICdub25lJzsKICAgICAgICAgICAgICAgIHF1ZXJ5ID0gJyc7CiAgICAgICAgICAgICAg
ICB3aW5kb3cuX19ob3N0RmlsdGVyZWQgPSBmYWxzZTsKICAgICAgICAgICAgICAgIC8vIFdpbitW77ya
56uL5Yi755So5pyq6L+H5ruk57yT5a2Y6ZO65YiX6KGo77yM6YG/5YWN5YWI6Zeq6L+H5ruk57uT5p6c
L+epuuWjs+WGjeetiSBTZXRWaWV3CiAgICAgICAgICAgICAgICB0cnkgewogICAgICAgICAgICAgICAg
ICAgIGNvbnN0IGhpdCA9IHZpZXdNZW0uZ2V0KHZpZXdNZW1LZXkoJ2FsbCcsICcnLCBmYWxzZSkpOwog
ICAgICAgICAgICAgICAgICAgIGlmIChoaXQgJiYgQXJyYXkuaXNBcnJheShoaXQuaXRlbXMpICYmIGhp
dC5pdGVtcy5sZW5ndGgpIHsKICAgICAgICAgICAgICAgICAgICAgICAgYWxsQ2xpcHMgPSBoaXQuaXRl
bXMuc2xpY2UoKTsKICAgICAgICAgICAgICAgICAgICAgICAgZGlza1RvdGFsID0gTnVtYmVyKGhpdC50
b3RhbCkgfHwgaGl0Lml0ZW1zLmxlbmd0aDsKICAgICAgICAgICAgICAgICAgICAgICAgd2luZG93Ll9f
ZGF0YVJlYWR5ID0gdHJ1ZTsKICAgICAgICAgICAgICAgICAgICAgICAgc2V0Qm9vdExvYWRpbmcoZmFs
c2UpOwogICAgICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgIH0gY2F0Y2gge30KICAgICAg
ICAgICAgfSBlbHNlIGlmICh3cmFwKSB7CiAgICAgICAgICAgICAgICB3cmFwLmNsYXNzTGlzdC5hZGQo
J29wZW4nKTsKICAgICAgICAgICAgICAgIGlmIChzcmNoICYmIHNyY2gudmFsdWUpCiAgICAgICAgICAg
ICAgICAgICAgcXVlcnkgPSBzcmNoLnZhbHVlOwogICAgICAgICAgICAgICAgLy8gPz8g5pCc57Si77ya
5Zyo5Li75py66L+H5ruk57uT5p6c5Yiw6L6+5YmN77yM5YWI5oyJ5YWz6ZSu5a2X5pys5Zyw5ruk77yM
56aB5q2i6Zeq5Ye644CM5YWo6YOo44CNCiAgICAgICAgICAgICAgICBpZiAoU3RyaW5nKHF1ZXJ5IHx8
ICcnKS50cmltKCkpCiAgICAgICAgICAgICAgICAgICAgd2luZG93Ll9faG9zdEZpbHRlcmVkID0gZmFs
c2U7CiAgICAgICAgICAgIH0KICAgICAgICAgICAgdG9kYXlPbmx5ID0gZmFsc2U7CiAgICAgICAgICAg
IHRyeSB7CiAgICAgICAgICAgICAgICBjb25zdCBidG5Ub2RheSA9IGRvY3VtZW50LmdldEVsZW1lbnRC
eUlkKCdidG4tdG9kYXknKTsKICAgICAgICAgICAgICAgIGlmIChidG5Ub2RheSkgYnRuVG9kYXkuY2xh
c3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICAgICAgfSBjYXRjaCB7fQogICAgICAgICAgICBjdXJU
YWIgPSAnYWxsJzsKICAgICAgICAgICAgbG9hZGluZ01vcmUgPSBmYWxzZTsKICAgICAgICAgICAgbWFy
a1RhYignYWxsJyk7CiAgICAgICAgICAgIC8vIOS4jeimgSBhaGsoJ2JsdXJQYW5lbCcp77ya5Lya6Lef
IFNob3dQYW5lbCDmiqLnhKbngrnvvIxXaW4rVi8/PyDpg73lrrnmmJPpl6rjgIHkubHot7MKICAgICAg
ICAgICAgaWYgKHdpbmRvdy5fX3BlbmRpbmdTa2VsVGltZXIpIGNsZWFyVGltZW91dCh3aW5kb3cuX19w
ZW5kaW5nU2tlbFRpbWVyKTsKICAgICAgICAgICAgd2luZG93Ll9fcGVuZGluZ1NrZWxTaW5jZSA9IERh
dGUubm93KCk7CiAgICAgICAgICAgIHdpbmRvdy5fX3BlbmRpbmdTa2VsVGltZXIgPSBzZXRUaW1lb3V0
KCgpID0+IHsKICAgICAgICAgICAgICAgIHdpbmRvdy5fX3BlbmRpbmdTa2VsVGltZXIgPSAwOwogICAg
ICAgICAgICAgICAgaWYgKCF3aW5kb3cuX19kYXRhUmVhZHkpIHNldEJvb3RMb2FkaW5nKHRydWUpOwog
ICAgICAgICAgICB9LCAxODApOwogICAgICAgICAgICByZW5kZXIoKTsKICAgICAgICB9IGNhdGNoIHt9
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
b3B5JywgIGMgPT4gYWhrKCdjb3B5QnlJZCcsICAgICBTdHJpbmcoYy5pZCkpKTsKICAgIGN0eEJpbmQo
J2MtcGFzdGUnLCBjID0+IHsKICAgICAgICBtYXJrUGFzdGVkTG9jYWwoYy5pZCk7CiAgICAgICAgYWhr
KCdwYXN0ZScsIFN0cmluZyhjLmlkKSk7CiAgICB9KTsKICAgIGN0eEJpbmQoJ2MtcGluJywgICBjID0+
IGFoaygncGluJywgICAgICAgICAgIFN0cmluZyhjLmlkKSkpOwogICAgY3R4QmluZCgnYy10b3AnLCAg
IGMgPT4gYWhrKCdtb3ZlVG9Ub3AnLCAgICAgU3RyaW5nKGMuaWQpKSk7CiAgICBjdHhCaW5kKCdjLWNs
ZWFyLXBhc3RlZCcsIGMgPT4gYWhrKCdjbGVhclBhc3RlZCcsIFN0cmluZyhjLmlkKSkpOwogICAgY3R4
QmluZCgnYy1kZWwnLCAgIGMgPT4gewogICAgICAgIC8vIOacrOWcsOWFiOWIoO+8jOeVjOmdouS4jeWN
oe+8m0FISyDlkI7lj7DokL3nm5gKICAgICAgICB0cnkgewogICAgICAgICAgICBjb25zdCBpZCA9ICtj
LmlkOwogICAgICAgICAgICBhbGxDbGlwcyA9IGFsbENsaXBzLmZpbHRlcih4ID0+ICt4LmlkICE9PSBp
ZCk7CiAgICAgICAgICAgIGRpc2tUb3RhbCA9IE1hdGgubWF4KDAsIChOdW1iZXIoZGlza1RvdGFsKSB8
fCAwKSAtIDEpOwogICAgICAgICAgICBpZiAoK3NlbGVjdGVkSWQgPT09IGlkKSBzZWxlY3RlZElkID0g
YWxsQ2xpcHMubGVuZ3RoID8gYWxsQ2xpcHNbMF0uaWQgOiAwOwogICAgICAgICAgICByZW5kZXIoKTsK
ICAgICAgICB9IGNhdGNoIHt9CiAgICAgICAgYWhrKCdkZWxldGUnLCBTdHJpbmcoYy5pZCkpOwogICAg
fSk7CiAgICBjdHhCaW5kKCdjLXRpdGxlJywgYyA9PiBvcGVuVGl0bGVEbGcoYykpOwogICAgY3R4Qmlu
ZCgnYy1tZXJnZScsIGMgPT4gewogICAgICAgIGNvbnN0IGlkcyA9IChtdWx0aUlkcy5sZW5ndGggPj0g
MikgPyBtdWx0aUlkcy5zbGljZSgpIDogW107CiAgICAgICAgaWYgKGlkcy5sZW5ndGggPCAyKSByZXR1
cm47CiAgICAgICAgaWYgKCFpZHMuaW5jbHVkZXMoK2MuaWQpKSBpZHMucHVzaCgrYy5pZCk7CiAgICAg
ICAgYWhrKCdtZXJnZUZhdicsIGlkcy5qb2luKCcsJykpOwogICAgICAgIGNsZWFyTXVsdGkoKTsKICAg
IH0pOwogICAgY3R4QmluZCgnYy11bm1lcmdlJywgYyA9PiB7CiAgICAgICAgYWhrKCd1bm1lcmdlRmF2
JywgU3RyaW5nKGMuaWQpKTsKICAgICAgICBjbGVhck11bHRpKCk7CiAgICB9KTsKCiAgICBjb25zdCB0
aXRsZURsZyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0aXRsZS1kbGcnKTsKICAgIGNvbnN0IHRp
dGxlSW5wdXQgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGl0bGUtaW5wdXQnKTsKICAgIGxldCB0
aXRsZURsZ0NsaXAgPSBudWxsOwogICAgZnVuY3Rpb24gY2xvc2VUaXRsZURsZygpIHsKICAgICAgICBp
ZiAodGl0bGVEbGcpIHRpdGxlRGxnLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgdGl0bGVE
bGdDbGlwID0gbnVsbDsKICAgIH0KICAgIGZ1bmN0aW9uIG9wZW5UaXRsZURsZyhjKSB7CiAgICAgICAg
aGlkZUN0eCgpOwogICAgICAgIHRpdGxlRGxnQ2xpcCA9IGM7CiAgICAgICAgaWYgKHRpdGxlSW5wdXQp
IHRpdGxlSW5wdXQudmFsdWUgPSBTdHJpbmcoYy5mYXZUaXRsZSB8fCAnJykudHJpbSgpOwogICAgICAg
IGlmICh0aXRsZURsZykgdGl0bGVEbGcuY2xhc3NMaXN0LmFkZCgnb24nKTsKICAgICAgICBhaGsoJ2Zv
Y3VzUGFuZWwnKTsKICAgICAgICByZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4gewogICAgICAgICAg
ICB0cnkgeyB0aXRsZUlucHV0LmZvY3VzKCk7IHRpdGxlSW5wdXQuc2VsZWN0KCk7IH0gY2F0Y2gge30K
ICAgICAgICB9KTsKICAgIH0KICAgIGlmICh0aXRsZURsZykgewogICAgICAgIHRpdGxlRGxnLmFkZEV2
ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgICAgIGlmIChlLnRhcmdldCA9PT0gdGl0
bGVEbGcpIGNsb3NlVGl0bGVEbGcoKTsKICAgICAgICB9KTsKICAgIH0KICAgIGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCd0aXRsZS1jYW5jZWwnKT8uYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsK
ICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgIGNsb3NlVGl0bGVEbGcoKTsKICAgICAg
ICBhaGsoJ2JsdXJQYW5lbCcpOwogICAgfSk7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGl0
bGUtb2snKT8uYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICBlLnN0b3BQcm9w
YWdhdGlvbigpOwogICAgICAgIGlmICghdGl0bGVEbGdDbGlwKSByZXR1cm47CiAgICAgICAgY29uc3Qg
dCA9IFN0cmluZyh0aXRsZUlucHV0Py52YWx1ZSB8fCAnJykudHJpbSgpLnNsaWNlKDAsIDgwKTsKICAg
ICAgICBjb25zdCBpZCA9IFN0cmluZyh0aXRsZURsZ0NsaXAuaWQpOwogICAgICAgIC8vIE9wdGltaXN0
aWMgbG9jYWwgdXBkYXRlCiAgICAgICAgY29uc3QgaGl0ID0gYWxsQ2xpcHMuZmluZCh4ID0+ICt4Lmlk
ID09PSAraWQpOwogICAgICAgIGlmIChoaXQpIGhpdC5mYXZUaXRsZSA9IHQ7CiAgICAgICAgdGl0bGVE
bGdDbGlwLmZhdlRpdGxlID0gdDsKICAgICAgICBjbG9zZVRpdGxlRGxnKCk7CiAgICAgICAgYWhrKCdz
ZXRGYXZUaXRsZScsIGlkLCB0KTsKICAgICAgICBhaGsoJ2JsdXJQYW5lbCcpOwogICAgICAgIHJlbmRl
cigpOwogICAgfSk7CiAgICB0aXRsZUlucHV0Py5hZGRFdmVudExpc3RlbmVyKCdrZXlkb3duJywgZSA9
PiB7CiAgICAgICAgaWYgKGUua2V5ID09PSAnRW50ZXInKSB7CiAgICAgICAgICAgIGUucHJldmVudERl
ZmF1bHQoKTsKICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgZS5zdG9w
SW1tZWRpYXRlUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQo
J3RpdGxlLW9rJyk/LmNsaWNrKCk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAg
aWYgKGUua2V5ID09PSAnRXNjYXBlJykgewogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAg
ICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgIGNsb3NlVGl0bGVEbGcoKTsK
ICAgICAgICAgICAgYWhrKCdibHVyUGFuZWwnKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0K
ICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgfSwgdHJ1ZSk7CgogICAgZG9jdW1lbnQuZ2V0
RWxlbWVudEJ5SWQoJ3RhYnMnKS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAg
IGNvbnN0IHRhYiA9IGUudGFyZ2V0LmNsb3Nlc3QoJy50YWInKTsKICAgICAgICBpZiAoIXRhYiB8fCBl
LnRhcmdldC5jbG9zZXN0KCcjdGFiLWFjdGlvbnMnKSkgcmV0dXJuOwogICAgICAgIHNldFRhYih0YWIu
ZGF0YXNldC50YWIpOwogICAgfSk7CgogICAgY29uc3Qgc3JjaFdyYXAgPSBkb2N1bWVudC5nZXRFbGVt
ZW50QnlJZCgnc2VhcmNoLXdyYXAnKTsKICAgIGNvbnN0IGJ0blNlYXJjaCA9IGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCdidG4tc2VhcmNoJyk7CiAgICBjb25zdCBidG5Mb2NhdGUgPSBkb2N1bWVudC5nZXRF
bGVtZW50QnlJZCgnYnRuLWxvY2F0ZScpOwogICAgY29uc3QgYnRuVG9kYXkgPSBkb2N1bWVudC5nZXRF
bGVtZW50QnlJZCgnYnRuLXRvZGF5Jyk7CiAgICBjb25zdCBzcmNoID0gZG9jdW1lbnQuZ2V0RWxlbWVu
dEJ5SWQoJ3NlYXJjaCcpOwogICAgY29uc3Qgc2NsciA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdz
ZWFyY2gtY2xyJyk7CiAgICBsZXQgZGViOwoKICAgIHVwZGF0ZUxvY2F0ZUJ0bigpOwogICAgaWYgKGJ0
bkxvY2F0ZSkgewogICAgICAgIGJ0bkxvY2F0ZS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4g
ewogICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICBqdW1wVG9MYXN0UGFz
dGUoKTsKICAgICAgICB9KTsKICAgIH0KCiAgICBidG5Ub2RheS5hZGRFdmVudExpc3RlbmVyKCdtb3Vz
ZWRvd24nLCBlID0+IHsKICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgZS5zdG9wUHJv
cGFnYXRpb24oKTsKICAgIH0pOwogICAgYnRuVG9kYXkuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBl
ID0+IHsKICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgIGUucHJldmVudERlZmF1bHQo
KTsKICAgICAgICB0b2RheU9ubHkgPSAhdG9kYXlPbmx5OwogICAgICAgIGJ0blRvZGF5LmNsYXNzTGlz
dC50b2dnbGUoJ29uJywgdG9kYXlPbmx5KTsKICAgICAgICBsaXN0RWwuc2Nyb2xsVG9wID0gMDsKICAg
ICAgICByZXF1ZXN0VmlldygpOwogICAgICAgIHRyeSB7IHNyY2guZm9jdXMoKTsgfSBjYXRjaCB7fQog
ICAgfSk7CgogICAgZnVuY3Rpb24gb3BlblNlYXJjaCgpIHsKICAgICAgICBpZiAoc3JjaFdyYXAuY2xh
c3NMaXN0LmNvbnRhaW5zKCdvcGVuJykpIHsKICAgICAgICAgICAgYWhrKCdmb2N1c1BhbmVsJyk7CiAg
ICAgICAgICAgIHRyeSB7IHNyY2guZm9jdXMoKTsgfSBjYXRjaCB7fQogICAgICAgICAgICByZXR1cm47
CiAgICAgICAgfQogICAgICAgIHNyY2hXcmFwLmNsYXNzTGlzdC5hZGQoJ29wZW4nKTsKICAgICAgICAv
LyBEZWZhdWx0OiDmiYDmnInpobXmiZPlvIDmkJzntKLml7bpu5jorqTmkJzlhajpg6gKICAgICAgICBj
b25zdCB3YW50VG9kYXkgPSBmYWxzZTsKICAgICAgICBpZiAodG9kYXlPbmx5ICE9PSB3YW50VG9kYXkp
IHsKICAgICAgICAgICAgdG9kYXlPbmx5ID0gd2FudFRvZGF5OwogICAgICAgICAgICBidG5Ub2RheS5j
bGFzc0xpc3QudG9nZ2xlKCdvbicsIHRvZGF5T25seSk7CiAgICAgICAgICAgIGxpc3RFbC5zY3JvbGxU
b3AgPSAwOwogICAgICAgICAgICByZXF1ZXN0VmlldygpOwogICAgICAgIH0gZWxzZSB7CiAgICAgICAg
ICAgIGJ0blRvZGF5LmNsYXNzTGlzdC50b2dnbGUoJ29uJywgdG9kYXlPbmx5KTsKICAgICAgICB9CiAg
ICAgICAgYWhrKCdmb2N1c1BhbmVsJyk7CiAgICAgICAgcmVxdWVzdEFuaW1hdGlvbkZyYW1lKCgpID0+
IHsKICAgICAgICAgICAgdHJ5IHsgc3JjaC5mb2N1cygpOyB9IGNhdGNoIHt9CiAgICAgICAgfSk7CiAg
ICB9CiAgICBmdW5jdGlvbiBjbG9zZVNlYXJjaFVpKCkgewogICAgICAgIHNyY2hXcmFwLmNsYXNzTGlz
dC5yZW1vdmUoJ29wZW4nKTsKICAgICAgICBpZiAoIXNyY2gudmFsdWUpIHsKICAgICAgICAgICAgc3Jj
aC5jbGFzc0xpc3QucmVtb3ZlKCdoYXMtdmFsJyk7CiAgICAgICAgICAgIHNjbHIuc3R5bGUuZGlzcGxh
eSA9ICdub25lJzsKICAgICAgICAgICAgLy8gTGVhdmluZyBzZWFyY2ggd2l0aCBlbXB0eSBxdWVyeSDi
hpIgZHJvcCB0b2RheSBmaWx0ZXIKICAgICAgICAgICAgaWYgKHRvZGF5T25seSkgewogICAgICAgICAg
ICAgICAgdG9kYXlPbmx5ID0gZmFsc2U7CiAgICAgICAgICAgICAgICBidG5Ub2RheS5jbGFzc0xpc3Qu
cmVtb3ZlKCdvbicpOwogICAgICAgICAgICAgICAgcmVxdWVzdFZpZXcoKTsKICAgICAgICAgICAgfQog
ICAgICAgIH0KICAgIH0KICAgIHdpbmRvdy5fX29wZW5TZWFyY2ggPSBvcGVuU2VhcmNoOwogICAgd2lu
ZG93Ll9fcHJlcFR5cGVTZWFyY2ggPSAoKSA9PiB7CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgY29u
c3Qgd3JhcCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gtd3JhcCcpOwogICAgICAgICAg
ICBjb25zdCBzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaCcpOwogICAgICAgICAgICBp
ZiAod3JhcCAmJiAhd3JhcC5jbGFzc0xpc3QuY29udGFpbnMoJ29wZW4nKSkgewogICAgICAgICAgICAg
ICAgd3JhcC5jbGFzc0xpc3QuYWRkKCdvcGVuJyk7CiAgICAgICAgICAgICAgICB0cnkgewogICAgICAg
ICAgICAgICAgICAgIGNvbnN0IHdhbnRUb2RheSA9IGZhbHNlOwogICAgICAgICAgICAgICAgICAgIGlm
ICh0eXBlb2YgdG9kYXlPbmx5ICE9PSAndW5kZWZpbmVkJyAmJiB0b2RheU9ubHkgIT09IHdhbnRUb2Rh
eSkgewogICAgICAgICAgICAgICAgICAgICAgICB0b2RheU9ubHkgPSB3YW50VG9kYXk7CiAgICAgICAg
ICAgICAgICAgICAgICAgIGlmICh0eXBlb2YgYnRuVG9kYXkgIT09ICd1bmRlZmluZWQnICYmIGJ0blRv
ZGF5KSBidG5Ub2RheS5jbGFzc0xpc3QudG9nZ2xlKCdvbicsIHRvZGF5T25seSk7CiAgICAgICAgICAg
ICAgICAgICAgICAgIGlmICh0eXBlb2YgbGlzdEVsICE9PSAndW5kZWZpbmVkJyAmJiBsaXN0RWwpIGxp
c3RFbC5zY3JvbGxUb3AgPSAwOwogICAgICAgICAgICAgICAgICAgICAgICBpZiAodHlwZW9mIHJlcXVl
c3RWaWV3ID09PSAnZnVuY3Rpb24nKSBzZXRUaW1lb3V0KHJlcXVlc3RWaWV3LCAwKTsKICAgICAgICAg
ICAgICAgICAgICB9IGVsc2UgaWYgKHR5cGVvZiBidG5Ub2RheSAhPT0gJ3VuZGVmaW5lZCcgJiYgYnRu
VG9kYXkpIHsKICAgICAgICAgICAgICAgICAgICAgICAgYnRuVG9kYXkuY2xhc3NMaXN0LnRvZ2dsZSgn
b24nLCAhIXRvZGF5T25seSk7CiAgICAgICAgICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgfSBj
YXRjaCB7fQogICAgICAgICAgICB9CiAgICAgICAgICAgIC8vID8/IOmVnOWDj+aQnOe0ou+8muS4jeim
gSBmb2N1c++8jOmBv+WFjeaKoui1sOWOn+e8lui+keahhuWFieaghwogICAgICAgIH0gY2F0Y2gge30K
ICAgIH07CiAgICB3aW5kb3cuX190eXBlU2VhcmNoID0gKGNoKSA9PiB7CiAgICAgICAgdHJ5IHsKICAg
ICAgICAgICAgd2luZG93Ll9fcHJlcFR5cGVTZWFyY2ggJiYgd2luZG93Ll9fcHJlcFR5cGVTZWFyY2go
KTsKICAgICAgICAgICAgY29uc3QgcyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gnKTsK
ICAgICAgICAgICAgaWYgKCFzKSByZXR1cm47CiAgICAgICAgICAgIHMudmFsdWUgPSBTdHJpbmcocy52
YWx1ZSB8fCAnJykgKyBTdHJpbmcoY2ggPT0gbnVsbCA/ICcnIDogY2gpOwogICAgICAgICAgICBzLmNs
YXNzTGlzdC50b2dnbGUoJ2hhcy12YWwnLCAhIXMudmFsdWUpOwogICAgICAgICAgICBzLmRpc3BhdGNo
RXZlbnQobmV3IEV2ZW50KCdpbnB1dCcsIHsgYnViYmxlczogdHJ1ZSB9KSk7CiAgICAgICAgfSBjYXRj
aCB7fQogICAgfTsKICAgIHdpbmRvdy5fX2Jrc3BTZWFyY2ggPSAoKSA9PiB7CiAgICAgICAgdHJ5IHsK
ICAgICAgICAgICAgd2luZG93Ll9fcHJlcFR5cGVTZWFyY2ggJiYgd2luZG93Ll9fcHJlcFR5cGVTZWFy
Y2goKTsKICAgICAgICAgICAgY29uc3QgcyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gn
KTsKICAgICAgICAgICAgaWYgKCFzKSByZXR1cm47CiAgICAgICAgICAgIGNvbnN0IHYgPSBTdHJpbmco
cy52YWx1ZSB8fCAnJyk7CiAgICAgICAgICAgIHMudmFsdWUgPSB2Lmxlbmd0aCA/IHYuc2xpY2UoMCwg
LTEpIDogJyc7CiAgICAgICAgICAgIHMuY2xhc3NMaXN0LnRvZ2dsZSgnaGFzLXZhbCcsICEhcy52YWx1
ZSk7CiAgICAgICAgICAgIHMuZGlzcGF0Y2hFdmVudChuZXcgRXZlbnQoJ2lucHV0JywgeyBidWJibGVz
OiB0cnVlIH0pKTsKICAgICAgICB9IGNhdGNoIHt9CiAgICB9OwogICAgd2luZG93Ll9fc2V0U2VhcmNo
UXVlcnkgPSAocSkgPT4gewogICAgICAgIHRyeSB7CiAgICAgICAgICAgIGNvbnN0IHMgPSBkb2N1bWVu
dC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoJyk7CiAgICAgICAgICAgIGlmICghcykgcmV0dXJuOwogICAg
ICAgICAgICAvLyDmiZPlrZfljbPml7bkuIrlsY/vvIzkuI7no4Hnm5jmkJzntKLop6PogKYKICAgICAg
ICAgICAgcy52YWx1ZSA9IFN0cmluZyhxID09IG51bGwgPyAnJyA6IHEpOwogICAgICAgICAgICBzLmNs
YXNzTGlzdC50b2dnbGUoJ2hhcy12YWwnLCAhIXMudmFsdWUpOwogICAgICAgICAgICBjb25zdCBzY2xy
ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaC1jbHInKTsKICAgICAgICAgICAgaWYgKHNj
bHIpIHNjbHIuc3R5bGUuZGlzcGxheSA9IHMudmFsdWUgPyAnYmxvY2snIDogJ25vbmUnOwogICAgICAg
ICAgICBxdWVyeSA9IHMudmFsdWU7CiAgICAgICAgICAgIHRyeSB7CiAgICAgICAgICAgICAgICBjb25z
dCB3cmFwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaC13cmFwJyk7CiAgICAgICAgICAg
ICAgICBpZiAod3JhcCAmJiAhd3JhcC5jbGFzc0xpc3QuY29udGFpbnMoJ29wZW4nKSkKICAgICAgICAg
ICAgICAgICAgICB3aW5kb3cuX19wcmVwVHlwZVNlYXJjaCAmJiB3aW5kb3cuX19wcmVwVHlwZVNlYXJj
aCgpOwogICAgICAgICAgICAgICAgZWxzZSBpZiAod3JhcCkKICAgICAgICAgICAgICAgICAgICB3cmFw
LmNsYXNzTGlzdC5hZGQoJ29wZW4nKTsKICAgICAgICAgICAgfSBjYXRjaCB7fQogICAgICAgICAgICB0
cnkgewogICAgICAgICAgICAgICAgY29uc3QgY250ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Jh
ci10eHQnKTsKICAgICAgICAgICAgICAgIGlmIChjbnQgJiYgU3RyaW5nKHF1ZXJ5IHx8ICcnKS50cmlt
KCkpCiAgICAgICAgICAgICAgICAgICAgY250LnRleHRDb250ZW50ID0gdmlzaWJsZUxpc3QoKS5sZW5n
dGggKyAnIOadoSc7CiAgICAgICAgICAgIH0gY2F0Y2gge30KICAgICAgICB9IGNhdGNoIHt9CiAgICB9
OwogICAgLy8gQ2FwdHVyZSBDdHJsK0YgaW5zaWRlIFdlYlZpZXcgKENocm9taXVtIGZpbmQgaXMgZGlz
YWJsZWQsIGJ1dCBzdGlsbCBoYW5kbGUgaGVyZSkKICAgIGRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIo
J2tleWRvd24nLCBlID0+IHsKICAgICAgICBpZiAoKGUuY3RybEtleSB8fCBlLm1ldGFLZXkpICYmICFl
LmFsdEtleSAmJiAoZS5rZXkgPT09ICdmJyB8fCBlLmtleSA9PT0gJ0YnKSkgewogICAgICAgICAgICBl
LnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAg
ICAgIG9wZW5TZWFyY2goKTsKICAgICAgICB9CiAgICB9LCB0cnVlKTsKICAgIGJ0blNlYXJjaC5hZGRF
dmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAg
ICAgICAgb3BlblNlYXJjaCgpOwogICAgfSk7CiAgICBsZXQgX19zcmNoQ29tcG9zaW5nID0gZmFsc2U7
CiAgICBjb25zdCBfX2ZsdXNoU2VhcmNoSW5wdXQgPSAoKSA9PiB7CiAgICAgICAgcXVlcnkgPSBzcmNo
LnZhbHVlOwogICAgICAgIHNyY2guY2xhc3NMaXN0LnRvZ2dsZSgnaGFzLXZhbCcsICEhcXVlcnkpOwog
ICAgICAgIHNjbHIuc3R5bGUuZGlzcGxheSA9IHF1ZXJ5ID8gJ2Jsb2NrJyA6ICdub25lJzsKICAgICAg
ICBsaXN0RWwuc2Nyb2xsVG9wID0gMDsKICAgICAgICBjbGVhclRpbWVvdXQoZGViKTsKICAgICAgICBk
ZWIgPSBzZXRUaW1lb3V0KHJlcXVlc3RWaWV3LCAxODApOwogICAgfTsKICAgIHNyY2guYWRkRXZlbnRM
aXN0ZW5lcignY29tcG9zaXRpb25zdGFydCcsICgpID0+IHsgX19zcmNoQ29tcG9zaW5nID0gdHJ1ZTsg
fSk7CiAgICBzcmNoLmFkZEV2ZW50TGlzdGVuZXIoJ2NvbXBvc2l0aW9uZW5kJywgKCkgPT4gewogICAg
ICAgIF9fc3JjaENvbXBvc2luZyA9IGZhbHNlOwogICAgICAgIF9fZmx1c2hTZWFyY2hJbnB1dCgpOwog
ICAgfSk7CiAgICBzcmNoLmFkZEV2ZW50TGlzdGVuZXIoJ2lucHV0JywgKCkgPT4gewogICAgICAgIGlm
IChfX3NyY2hDb21wb3NpbmcpIHsKICAgICAgICAgICAgcXVlcnkgPSBzcmNoLnZhbHVlOwogICAgICAg
ICAgICBzcmNoLmNsYXNzTGlzdC50b2dnbGUoJ2hhcy12YWwnLCAhIXF1ZXJ5KTsKICAgICAgICAgICAg
c2Nsci5zdHlsZS5kaXNwbGF5ID0gcXVlcnkgPyAnYmxvY2snIDogJ25vbmUnOwogICAgICAgICAgICBy
ZXR1cm47CiAgICAgICAgfQogICAgICAgIF9fZmx1c2hTZWFyY2hJbnB1dCgpOwogICAgfSk7CiAgICBz
cmNoLmFkZEV2ZW50TGlzdGVuZXIoJ2ZvY3VzJywgKCkgPT4gewogICAgICAgIC8vIElkZW1wb3RlbnQg
b24gQUhLIHNpZGUg4oCUIHNhZmUsIGJ1dCBhdm9pZCBzcGFtbWluZyBkdXJpbmcgSU1FCiAgICAgICAg
dHJ5IHsgYWhrKCdmb2N1c1BhbmVsJyk7IH0gY2F0Y2gge30KICAgIH0pOwogICAgc3JjaC5hZGRFdmVu
dExpc3RlbmVyKCdibHVyJywgKCkgPT4gewogICAgICAgIHNldFRpbWVvdXQoKCkgPT4gewogICAgICAg
ICAgICBpZiAoZG9jdW1lbnQuYWN0aXZlRWxlbWVudCA9PT0gc3JjaCkgcmV0dXJuOwogICAgICAgICAg
ICBpZiAoZG9jdW1lbnQuYWN0aXZlRWxlbWVudCA9PT0gc2NsciB8fCAoc2NsciAmJiBzY2xyLmNvbnRh
aW5zKGRvY3VtZW50LmFjdGl2ZUVsZW1lbnQpKSkgcmV0dXJuOwogICAgICAgICAgICBpZiAoZG9jdW1l
bnQuYWN0aXZlRWxlbWVudCA9PT0gYnRuVG9kYXkgfHwgKGJ0blRvZGF5ICYmIGJ0blRvZGF5LmNvbnRh
aW5zKGRvY3VtZW50LmFjdGl2ZUVsZW1lbnQpKSkgcmV0dXJuOwogICAgICAgICAgICAvLyBJTUUgY2Fu
ZGlkYXRlIFVJIHN0ZWFscyBmb2N1cyBicmllZmx5IOKAlCBrZWVwIHNlYXJjaCBpZiBzdGlsbCBjb21w
b3NpbmcKICAgICAgICAgICAgaWYgKF9fc3JjaENvbXBvc2luZykgcmV0dXJuOwogICAgICAgICAgICBj
bG9zZVNlYXJjaFVpKCk7CiAgICAgICAgICAgIGFoaygnYmx1clBhbmVsJyk7CiAgICAgICAgfSwgMjgw
KTsKICAgIH0pOwogICAgc3JjaC5hZGRFdmVudExpc3RlbmVyKCdrZXlkb3duJywgZSA9PiB7CiAgICAg
ICAgLy8gQ3RybCtJIC8gQ3RybCtLOiBtb3ZlIGNsaXAgc2VsZWN0aW9uIChub3QgaW5zZXJ0IGNoYXIg
LyBicm93c2VyIHNob3J0Y3V0KQogICAgICAgIGlmICgoZS5jdHJsS2V5IHx8IGUubWV0YUtleSkgJiYg
KGUua2V5ID09PSAnaScgfHwgZS5rZXkgPT09ICdJJykpIHsKICAgICAgICAgICAgZS5wcmV2ZW50RGVm
YXVsdCgpOwogICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICB3aW5kb3cu
X19uYXYgJiYgd2luZG93Ll9fbmF2KCd1cCcpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQog
ICAgICAgIGlmICgoZS5jdHJsS2V5IHx8IGUubWV0YUtleSkgJiYgKGUua2V5ID09PSAnaycgfHwgZS5r
ZXkgPT09ICdLJykpIHsKICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICBl
LnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICB3aW5kb3cuX19uYXYgJiYgd2luZG93Ll9fbmF2
KCdkb3duJyk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgaWYgKGUua2V5ID09
PSAnQXJyb3dEb3duJykgewogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAg
IGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgIHdpbmRvdy5fX25hdiAmJiB3aW5kb3cuX19u
YXYoJ2Rvd24nKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBpZiAoZS5rZXkg
PT09ICdBcnJvd1VwJykgewogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAg
IGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgIHdpbmRvdy5fX25hdiAmJiB3aW5kb3cuX19u
YXYoJ3VwJyk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgaWYgKGUua2V5ID09
PSAnRXNjYXBlJykgewogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgIGUu
c3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgIC8vIEFsd2F5cyBkaXNtaXNzIHRoZSB3aG9sZSBw
YW5lbCAobm90IGp1c3QgdGhlIHNlYXJjaCBmaWVsZCkKICAgICAgICAgICAgaWYgKCFwaW5uZWRVSSkg
YWhrKCdoaWRlJyk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgZS5zdG9wUHJv
cGFnYXRpb24oKTsKICAgIH0pOwogICAgc2Nsci5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4g
ewogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgc3JjaC52YWx1ZSA9IHF1ZXJ5ID0g
Jyc7CiAgICAgICAgc2Nsci5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOwogICAgICAgIHNyY2guY2xhc3NM
aXN0LnJlbW92ZSgnaGFzLXZhbCcpOwogICAgICAgIHJlcXVlc3RWaWV3KCk7CiAgICAgICAgYWhrKCdm
b2N1c1BhbmVsJyk7CiAgICAgICAgc3JjaC5mb2N1cygpOwogICAgfSk7CgogICAgY29uc3QgVEFCX05B
TUVTID0geyBhbGw6ICflhajpg6gnLCB0ZXh0OiAn5paH5pysJywgaW1hZ2U6ICflm77lg48nLCBmaWxl
OiAn5paH5Lu2JywgcGlubmVkOiAn5pS26JePJyB9OwogICAgY29uc3QgY2xyRGxnID0gZG9jdW1lbnQu
Z2V0RWxlbWVudEJ5SWQoJ2Nsci1kbGcnKTsKICAgIGNvbnN0IGNsckFsbENiID0gZG9jdW1lbnQuZ2V0
RWxlbWVudEJ5SWQoJ2Nsci1hbGwnKTsKICAgIGZ1bmN0aW9uIG9wZW5DbGVhckRsZygpIHsKICAgICAg
ICBjb25zdCBuYW1lID0gVEFCX05BTUVTW2N1clRhYl0gfHwgJ+W9k+WJjSc7CiAgICAgICAgZG9jdW1l
bnQuZ2V0RWxlbWVudEJ5SWQoJ2Nsci10aXRsZScpLnRleHRDb250ZW50ID0gJ+a4heepuuOAjCcgKyBu
YW1lICsgJ+OAje+8nyc7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Nsci1kZXNjJyku
dGV4dENvbnRlbnQgPSBjdXJUYWIgPT09ICdwaW5uZWQnCiAgICAgICAgICAgID8gJ+m7mOiupOS7hea4
heepuuW9k+WkqeeahOaUtuiXj+mhueOAguWLvumAieOAjOa4heepuuaJgOacieOAjeWPr+a4hemZpOiv
pemAiemhueWNoeWFqOmDqOWGheWuueOAgicKICAgICAgICAgICAgOiAn5LuF5riF56m65b2T5YmN6YCJ
6aG55Y2h44CC6buY6K6k5Y+q5riF5b2T5aSp77yb5pS26JeP6aG55LiN5Lya6KKr5riF6Zmk44CC5Yu+
6YCJ44CM5riF56m65omA5pyJ44CN5Y+v5riF6Zmk6K+l6YCJ6aG55Y2h5YWo6YOo5pel5pyf44CCJzsK
ICAgICAgICBjbHJBbGxDYi5jaGVja2VkID0gZmFsc2U7CiAgICAgICAgY2xyRGxnLmNsYXNzTGlzdC5h
ZGQoJ29uJyk7CiAgICB9CiAgICBmdW5jdGlvbiBjbG9zZUNsZWFyRGxnKCkgewogICAgICAgIGNsckRs
Zy5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgfQogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQo
J2J0bi1jbHInKS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGUuc3RvcFBy
b3BhZ2F0aW9uKCk7CiAgICAgICAgb3BlbkNsZWFyRGxnKCk7CiAgICB9KTsKICAgIGRvY3VtZW50Lmdl
dEVsZW1lbnRCeUlkKCdjbHItY2FuY2VsJykuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsK
ICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgIGNsb3NlQ2xlYXJEbGcoKTsKICAgIH0p
OwogICAgY2xyRGxnLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgaWYgKGUu
dGFyZ2V0ID09PSBjbHJEbGcpIGNsb3NlQ2xlYXJEbGcoKTsKICAgIH0pOwogICAgZG9jdW1lbnQuZ2V0
RWxlbWVudEJ5SWQoJ2Nsci1vaycpLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAg
ICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICBjb25zdCBzY29wZSA9IGNsckFsbENiLmNoZWNr
ZWQgPyAnYWxsJyA6ICd0b2RheSc7CiAgICAgICAgY2xvc2VDbGVhckRsZygpOwogICAgICAgIGFoaygn
Y2xlYXInLCBjdXJUYWIsIHNjb3BlKTsKICAgIH0pOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQo
J211bHRpLWNudCcpLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgZS5zdG9w
UHJvcGFnYXRpb24oKTsKICAgICAgICBjbGVhck11bHRpKHRydWUpOwogICAgfSk7CiAgICBkb2N1bWVu
dC5nZXRFbGVtZW50QnlJZCgnYnRuLXBpbicpLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7
CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICBwaW5uZWRVSSA9ICFwaW5uZWRVSTsK
ICAgICAgICBlLmN1cnJlbnRUYXJnZXQuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCBwaW5uZWRVSSk7CiAg
ICAgICAgYWhrKCd0b2dnbGVQaW4nLCBwaW5uZWRVSSA/ICcxJyA6ICcwJyk7CiAgICB9KTsKCiAgICB3
aW5kb3cuX191cGRhdGVDbGlwcyA9IHBheWxvYWQgPT4gewogICAgICAgIC8vIEtlZXAgcHJldmlvdXMg
c2Nyb2xsIGZvciBsb2FkLW1vcmU7IHJlc2V0IHdoZW4gb3BlbmluZyBwYW5lbCB0byBmaXJzdCBpdGVt
CiAgICAgICAgY29uc3Qga2VlcFNjcm9sbCA9ICFzZWxlY3RGaXJzdE9uU2hvdzsKICAgICAgICBjb25z
dCBzdCA9IGxpc3RFbC5zY3JvbGxUb3A7CiAgICAgICAgLy8g5pWw5o2u5Yiw5LqG77yM5Y+W5raIIHNl
dFRhYiDmjpLpmJ/nmoTjgIzlu7bov5/pqqjmnrbjgI10aW1lcu+8iOmBv+WFjeWug+WIsOeCueWQjuWP
iOW8gCBza2VsZXRvbu+8iQogICAgICAgIHdpbmRvdy5fX3dhaXRpbmdWaWV3ID0gZmFsc2U7CiAgICAg
ICAgaWYgKHdpbmRvdy5fX3BlbmRpbmdTa2VsVGltZXIpIHsKICAgICAgICAgICAgY2xlYXJUaW1lb3V0
KHdpbmRvdy5fX3BlbmRpbmdTa2VsVGltZXIpOwogICAgICAgICAgICB3aW5kb3cuX19wZW5kaW5nU2tl
bFRpbWVyID0gMDsKICAgICAgICB9CiAgICAgICAgd2luZG93Ll9fcGVuZGluZ1NrZWxTaW5jZSA9IDA7
CiAgICAgICAgY29uc3Qgd2FzQXBwZW5kID0gcGF5bG9hZCAmJiBwYXlsb2FkLmFwcGVuZDsKICAgICAg
ICBsb2FkaW5nTW9yZSA9IGZhbHNlOwogICAgICAgIGNvbnN0IHByZXZJdGVtcyA9IGFsbENsaXBzOwog
ICAgICAgIGlmIChBcnJheS5pc0FycmF5KHBheWxvYWQpKSB7CiAgICAgICAgICAgIGFsbENsaXBzID0g
cGF5bG9hZDsKICAgICAgICAgICAgZGlza1RvdGFsID0gcGF5bG9hZC5sZW5ndGg7CiAgICAgICAgICAg
IHdpbmRvdy5fX2hvc3RGaWx0ZXJlZCA9IGZhbHNlOwogICAgICAgIH0gZWxzZSBpZiAocGF5bG9hZCAm
JiB0eXBlb2YgcGF5bG9hZCA9PT0gJ29iamVjdCcpIHsKICAgICAgICAgICAgZGlza1RvdGFsID0gTnVt
YmVyKHBheWxvYWQudG90YWwpIHx8IDA7CiAgICAgICAgICAgIGNvbnN0IGl0ZW1zID0gQXJyYXkuaXNB
cnJheShwYXlsb2FkLml0ZW1zKSA/IHBheWxvYWQuaXRlbXMgOiBbXTsKICAgICAgICAgICAgaWYgKHBh
eWxvYWQuYXBwZW5kKSB7CiAgICAgICAgICAgICAgICBjb25zdCBzZWVuID0gbmV3IFNldChhbGxDbGlw
cy5tYXAoYyA9PiArYy5pZCkpOwogICAgICAgICAgICAgICAgaXRlbXMuZm9yRWFjaChpdCA9PiB7CiAg
ICAgICAgICAgICAgICAgICAgaWYgKCFzZWVuLmhhcygraXQuaWQpKSBhbGxDbGlwcy5wdXNoKGl0KTsK
ICAgICAgICAgICAgICAgIH0pOwogICAgICAgICAgICB9IGVsc2UgewogICAgICAgICAgICAgICAgYWxs
Q2xpcHMgPSBpdGVtczsKICAgICAgICAgICAgfQogICAgICAgICAgICAvLyDkuLvmnLrlt7LmjIkgcXVl
cnkg6L+H5ruk77ya5L+h5Lu757uT5p6c77yIcHJldmlldyDkuI3lkKvlhbPplK7lrZfml7bkuZ/kuI3o
poHliY3nq6/lho3mnYDvvIkKICAgICAgICAgICAgY29uc3QgcHEgPSBwYXlsb2FkLnF1ZXJ5ICE9IG51
bGwgPyBTdHJpbmcocGF5bG9hZC5xdWVyeSkgOiAnJzsKICAgICAgICAgICAgd2luZG93Ll9faG9zdEZp
bHRlcmVkID0gISEocGF5bG9hZC5maWx0ZXJlZCB8fCAocHEgJiYgcHEudHJpbSgpKSk7CiAgICAgICAg
ICAgIC8vIOaQnOe0ouahhuS7peaJk+Wtl+mVnOWDj+S4uuWHhu+8jOe7neS4jeiiq+a7nuWQjueahOej
geebmOe7k+aenOWGmeWbnuaXp+WFs+mUruWtlwogICAgICAgICAgICB0cnkgewogICAgICAgICAgICAg
ICAgY29uc3QgcyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gnKTsKICAgICAgICAgICAg
ICAgIGlmIChzICYmIFN0cmluZyhzLnZhbHVlIHx8ICcnKS5sZW5ndGgpCiAgICAgICAgICAgICAgICAg
ICAgcXVlcnkgPSBzLnZhbHVlOwogICAgICAgICAgICAgICAgZWxzZSBpZiAocHEgIT09ICcnICYmICFT
dHJpbmcocXVlcnkgfHwgJycpLnRyaW0oKSkKICAgICAgICAgICAgICAgICAgICBxdWVyeSA9IHBxOwog
ICAgICAgICAgICB9IGNhdGNoIHt9CiAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgYWxsQ2xpcHMg
PSBbXTsKICAgICAgICAgICAgZGlza1RvdGFsID0gMDsKICAgICAgICAgICAgd2luZG93Ll9faG9zdEZp
bHRlcmVkID0gZmFsc2U7CiAgICAgICAgfQogICAgICAgIGlmICghd2FzQXBwZW5kKSB7CiAgICAgICAg
ICAgIGNvbnN0IG1lbVEgPSAocGF5bG9hZCAmJiB0eXBlb2YgcGF5bG9hZCA9PT0gJ29iamVjdCcgJiYg
cGF5bG9hZC5xdWVyeSAhPSBudWxsKQogICAgICAgICAgICAgICAgPyBTdHJpbmcocGF5bG9hZC5xdWVy
eSkgOiBxdWVyeTsKICAgICAgICAgICAgdmlld01lbS5zZXQodmlld01lbUtleShjdXJUYWIsIG1lbVEs
IHRvZGF5T25seSksIHsKICAgICAgICAgICAgICAgIGl0ZW1zOiBhbGxDbGlwcy5zbGljZSgpLAogICAg
ICAgICAgICAgICAgdG90YWw6IGRpc2tUb3RhbAogICAgICAgICAgICB9KTsKICAgICAgICB9CiAgICAg
ICAgd2luZG93Ll9fZGF0YVJlYWR5ID0gdHJ1ZTsKICAgICAgICBjb25zdCB3YXNCb290TG9hZGluZyA9
IGJvb3RMb2FkaW5nOwogICAgICAgIGxldCBzYW1lUGFpbnQgPSBmYWxzZTsKICAgICAgICBpZiAoIXdh
c0FwcGVuZCAmJiAhd2FzQm9vdExvYWRpbmcgJiYgcHJldkl0ZW1zICYmIHByZXZJdGVtcy5sZW5ndGgg
PT09IGFsbENsaXBzLmxlbmd0aCAmJiBwcmV2SXRlbXMubGVuZ3RoKSB7CiAgICAgICAgICAgIHNhbWVQ
YWludCA9IHRydWU7CiAgICAgICAgICAgIGZvciAobGV0IGkgPSAwOyBpIDwgYWxsQ2xpcHMubGVuZ3Ro
OyBpKyspIHsKICAgICAgICAgICAgICAgIGlmICgrcHJldkl0ZW1zW2ldLmlkICE9PSArYWxsQ2xpcHNb
aV0uaWQpIHsgc2FtZVBhaW50ID0gZmFsc2U7IGJyZWFrOyB9CiAgICAgICAgICAgIH0KICAgICAgICAg
ICAgaWYgKHNhbWVQYWludCAmJiAhbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5pdG0nKSkgc2FtZVBhaW50
ID0gZmFsc2U7CiAgICAgICAgfQogICAgICAgIGNvbnN0IGZpbmlzaFVwZGF0ZSA9ICgpID0+IHsKICAg
ICAgICAgICAgc2V0Qm9vdExvYWRpbmcoZmFsc2UpOwogICAgICAgICAgICBpZiAoIXNhbWVQYWludCkg
ewogICAgICAgICAgICAgICAgcmVuZGVyKCk7CiAgICAgICAgICAgICAgICBhcHBseVRhYlN3aXRjaEFu
aW0oKTsKICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAoa2VlcFNjcm9sbCkKICAgICAgICAgICAg
ICAgIGxpc3RFbC5zY3JvbGxUb3AgPSBzdDsKICAgICAgICAgICAgZWxzZSBpZiAoIXNhbWVQYWludCkK
ICAgICAgICAgICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSAwOwogICAgICAgIH07CiAgICAgICAgaWYg
KHdhc0Jvb3RMb2FkaW5nKSB7CiAgICAgICAgICAgIGNvbnN0IHNpbmNlID0gd2luZG93Ll9fc2tlbFNp
bmNlIHx8IDA7CiAgICAgICAgICAgIGNvbnN0IHdhaXQgPSBzaW5jZSA/IE1hdGgubWF4KDAsIDgwIC0g
KERhdGUubm93KCkgLSBzaW5jZSkpIDogMDsKICAgICAgICAgICAgaWYgKHdhaXQgPiAwKQogICAgICAg
ICAgICAgICAgc2V0VGltZW91dChmaW5pc2hVcGRhdGUsIHdhaXQpOwogICAgICAgICAgICBlbHNlCiAg
ICAgICAgICAgICAgICBmaW5pc2hVcGRhdGUoKTsKICAgICAgICB9IGVsc2UgewogICAgICAgICAgICBm
aW5pc2hVcGRhdGUoKTsKICAgICAgICB9CiAgICB9OwogICAgd2luZG93Ll9fc2V0UGlubmVkID0gdiA9
PiB7CiAgICAgICAgcGlubmVkVUkgPSAhIXY7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQo
J2J0bi1waW4nKS5jbGFzc0xpc3QudG9nZ2xlKCdvbicsIHBpbm5lZFVJKTsKICAgIH07CiAgICB3aW5k
b3cuX19sb2FkTW9yZURvbmUgPSAoKSA9PiB7CiAgICAgICAgbG9hZGluZ01vcmUgPSBmYWxzZTsKICAg
IH07CgogICAgcmVxdWVzdFZpZXcoKTsKICAgIHJlbmRlcigpOwoKICAgIDwvc2NyaXB0Pgo8L2JvZHk+
CjwvaHRtbD4=
)"

global clips   := []
global clipUidSeq := 0
global lastAppendCount := 0
global viewTab := "all"
global viewQuery := ""
global viewToday := false
global viewTotal := 0
global viewCache := Map()
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
    pasteMany(ids) {
        RequestPasteMany(ids)
    }
    delete(id) {
        ; 立刻返回，避免 WebView 同步调用卡死界面
        SetTimer(DeleteItem.Bind(id), -1)
    }
    pin(id) {
        PinItem(id)
    }
    clear(tab := "all", scope := "today") {
        SetTimer(ClearTab.Bind(tab, scope), -1)
    }
    hide(*) {
        HidePanel()
    }
    moveToTop(id) {
        MoveToTop(id)
    }
    copyById(id) {
        CopyById(id)
    }
    clearPasted(id) {
        ClearPasted(id)
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
    global guiWin, wv, wvCore, lastCaretX, lastCaretY, hasCaretPos, panelVisible, uiPinned, prevActiveWin, linkMetaPausedUntil, viewToday, qqSearchOn, qqQuery
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
            q := Trim(String(qqQuery))
            if q != ""
                SetTimer(() => (SetView("all", qqQuery, "0"), RequestUiPush()), -30)
        } else
            SetTimer(() => (SetView("all", "", "0"), RequestUiPush()), -30)
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
    ; 搜索框立刻镜像；磁盘过滤可滞后
    QQPushQuery()
    SetTimer(QQApplyQueryView, -140)
}

QQApplyQueryView(*) {
    global qqSearchOn, qqQuery
    if !qqSearchOn
        return
    SetView("all", qqQuery, "0")
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
    global diskScanBusy, qqSearchOn
    ClipLog("WarmAllViews START")
    diskScanBusy := true
    try {
        ; 不要 Invalidate：清缓存会让随后切 tab 全走磁盘，又卡又容易误关面板
        PreloadAllViews("0")
        ClipLog("WarmAllViews Preload done")
        ; ?? 搜索中不要用空查询冲掉结果
        if !qqSearchOn
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
    if !IsObject(wvCore)
        return
    q := String(viewQuery)
    ; 扫盘中途可能 Sleep 让出：此时 viewQuery 已新、clips 仍旧 → 绝不推「伪过滤」列表
    if viewApplying && Trim(q) != ""
        return
    sendList := clips
    sendTotal := Integer(viewTotal)
    filtered := Trim(q) != ""
    if filtered {
        sendList := []
        for c in clips {
            if ItemMatchesView(c, viewTab, q, viewToday)
                sendList.Push(c)
        }
        ; 展示条数以实际命中为准（避免 total=20 却塞了未命中行）
        if !append
            sendTotal := sendList.Length
        else
            sendTotal := Max(Integer(viewTotal), sendList.Length)
    }
    payload := "{"
    payload .= '"append":' (append ? "true" : "false") ","
    payload .= '"total":' sendTotal ","
    payload .= '"query":' JsonStr(q) ","
    payload .= '"filtered":' (filtered ? "true" : "false") ","
    payload .= '"items":' ClipsListToJson(sendList, append)
    payload .= "}"
    try wvCore.ExecuteScriptAsync("window.__updateClips && window.__updateClips(" payload ");window.__loadMoreDone&&window.__loadMoreDone()")
    ; Virtual-host thumbs are unreliable (path spaces / WV2); inject data-URLs from AHK
    SetTimer(PushStoreThumbs.Bind(append), -60)
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

; Push list thumbnails via ExecuteScript (avoids sync hostObject size limits)
PushStoreThumbs(append := false) {
    global clips, wvCore, lastAppendCount, diskScanBusy, clipReady
    if !IsObject(wvCore)
        return
    if diskScanBusy || !clipReady {
        SetTimer(PushStoreThumbs.Bind(append), -300)
        return
    }
    start := 1
    if append && lastAppendCount > 0
        start := Max(1, clips.Length - lastAppendCount + 1)
    i := start
    pushed := 0
    while i <= clips.Length {
        c := clips[i]
        i += 1
        if !IsObject(c) || !c.HasProp("imgFile") || c.imgFile = ""
            continue
        if c.type != "image" && c.type != "file"
            continue
        url := ""
        try url := ListThumbDataUrl(c.imgFile)
        catch {
            continue
        }
        if url = ""
            continue
        try wvCore.ExecuteScriptAsync("window.__setThumb&&window.__setThumb(" Integer(c.uid) "," JsonStr(url) ")")
        pushed += 1
        Sleep(-1)
        ; Yield so first thumbs paint before generating the rest
        if Mod(pushed, 3) = 0
            Sleep(1)
    }
    if pushed
        ClipLog("PushStoreThumbs done n=" pushed " append=" append)
}

; Small JPEG list preview (cached next to original) —keeps inject payload small
ListThumbDataUrl(name) {
    global STORE_DIR
    name := String(name)
    if name = ""
        return ""
    src := STORE_DIR "\" name
    if !FileExist(src)
        return ""
    ; Create/refresh th_*.jpg when missing (safe outside Critical —was hung only under Critical)
    cacheName := ""
    try cacheName := EnsureListThumbFile(name)
    catch as e {
        ClipLog("ListThumbDataUrl EnsureListThumbFile fail name=" name " err=" e.Message)
    }
    if cacheName != "" {
        u := LoadImageFromStore(cacheName)
        if u != ""
            return u
    }
    ; Last resort: tiny originals only (large ExecuteScript payloads fail silently)
    try {
        if FileGetSize(src) <= 80000 {
            u := LoadImageFromStore(name)
            if u != ""
                return u
        }
    } catch {
    }
    return ""
}

EnsureListThumbFile(name) {
    global STORE_DIR
    src := STORE_DIR "\" name
    if !FileExist(src)
        return ""
    base := RegExReplace(name, "\.[^.]+$", "")
    cacheName := "th_" base ".jpg"
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

PasteMany(idsStr) {
    global prevActiveWin, clipIgnore, uiPinned
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
    global clips, viewTotal, wvCore, lastTxt, lastImg
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
    RequestUiPush()
    EnqueueDiskJob(PersistDeleteUid.Bind(uid, imgFile, itemType))
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
    ; Persist sync — line patch is fast; async queue raced with tab switch
    DiskSetPinned(uid, newPin, pinAt)
    if viewTab = "pinned" || viewQuery != ""
        SetView(viewTab, viewQuery, viewToday ? "1" : "0")
    else if IsObject(wvCore)
        PushClips(false)
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
    if IsObject(wvCore)
        PushClips(false)
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
    global STORE_DIR
    if !IsObject(item) || !item.HasProp("imgFile") || item.imgFile = ""
        return
    path := STORE_DIR "\" item.imgFile
    try {
        if FileExist(path)
            FileDelete path
    }
    ; Remove list-thumb cache too
    try {
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
        return m
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
    return m
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

ItemMatchesView(c, tab, query, todayOnly) {
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
            ; Screenshots + file clips whose path is an image format
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
    q := Trim(String(query))
    if q != "" {
        favTitle := c.HasProp("favTitle") ? String(c.favTitle) : ""
        ; a|b|c = AND（管线：须同时包含每一段），不是 OR
        ; 只搜列表能展示的字段，避免「正文深处命中、预览完全看不到」像搜错了
        hay := ""
        if type = "image" {
            hay := ""
        } else if type = "file" {
            hay := StrLower(String(c.HasProp("preview") ? c.preview : "") " "
                . String(c.HasProp("data") ? c.data : "") " " favTitle)
        } else {
            prev := c.HasProp("preview") ? String(c.preview) : ""
            if prev = "" && c.HasProp("data") && c.data != ""
                prev := SubStr(String(c.data), 1, 500)
            hay := StrLower(prev " "
                . String(c.HasProp("linkTitle") ? c.linkTitle : "") " " favTitle)
        }
        favLower := StrLower(favTitle)
        matchedAnyTerm := false
        for part in StrSplit(q, "|") {
            term := Trim(part)
            if term = ""
                continue
            matchedAnyTerm := true
            tLower := StrLower(term)
            if type = "image" {
                if favTitle = "" || !InStr(favLower, tLower)
                    return false
            } else if !InStr(hay, tLower) {
                return false
            }
        }
        ; 全是空段（如 "||"）→ 不当作命中全部
        if !matchedAnyTerm
            return false
    }
    return true
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
    tab := StrLower(Trim(String(tab)))
    if tab = "pinned"
        return QueryPinnedDiskPage(query, todayOnly, offset, limit)
    q := Trim(String(query))
    n := 0
    if q != "" {
        ; Search: collect all hits, expand fav-groups, then page
        all := []
        m := LoadManifest()
        for name in m["pages"] {
            for c in ReadPageFile(name, true) {
                if ItemMatchesView(c, tab, q, todayOnly)
                    all.Push(c)
                if Mod(++n, 48) = 0
                    Sleep(-1)
            }
        }
        ; 搜索必须严格命中关键字，不要 ExpandFavGroupHits 把同组无关键字条目带进来
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
    m := LoadManifest()
    for name in m["pages"] {
        for c in ReadPageFile(name, true) {
            if !ItemMatchesView(c, tab, query, todayOnly)
                continue
            if total >= offset && items.Length < limit
                items.Push(c)
            total += 1
            if Mod(++n, 48) = 0
                Sleep(-1)
        }
    }
    return { items: items, total: total }
}

; 收藏: newest pinTime first (not create time / disk order)
QueryPinnedDiskPage(query, todayOnly, offset, limit) {
    all := []
    m := LoadManifest()
    for name in m["pages"] {
        for c in ReadPageFile(name, true) {
            if ItemMatchesView(c, "pinned", query, todayOnly)
                all.Push(c)
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
    global viewCache
    viewCache := Map()
    ClipLog("InvalidateViewCache")
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
    global clips, viewTab, viewQuery, viewToday, viewTotal, viewCache, PAGE_SIZE
    ; Drop same uid anywhere first
    MemoryRemoveUid(item.uid)
    LiveFrontAdd(item)
    for key, entry in viewCache {
        tab := "", todayOnly := false, query := ""
        ParseViewCacheKey(key, &tab, &todayOnly, &query)
        if !ItemMatchesView(item, tab, query, todayOnly)
            continue
        entry.items.InsertAt(1, item)
        entry.total += 1
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
    global panelVisible
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
        }
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

PersistMoveToTop(item) {
    if !IsObject(item)
        return
    EnsureSpillPayload(item)
    DiskRemoveUid(item.uid)
    DiskInsertFront(item)
}

CacheCurrentView() {
    global viewCache, clips, viewTab, viewQuery, viewToday, viewTotal
    key := ViewCacheKey(viewTab, viewQuery, viewToday)
    cloned := []
    for c in clips
        cloned.Push(c)
    viewCache[key] := { items: cloned, total: viewTotal }
}

; Preload first VIEW_PAGE_SIZE for every tab in ONE disk pass (fast parse)
PreloadAllViews(today := "") {
    global viewCache, viewToday, VIEW_PAGE_SIZE, qqSearchOn
    ; 不要 Critical：切 tab / 预热时会卡住整线程，松手后外侧点击容易把面板藏掉
    try {
        if today = ""
            todayFlag := viewToday
        else
            todayFlag := (String(today) = "1" || String(today) = "true")
        tabs := ["all", "text", "image", "file", "link", "pinned"]
        buckets := Map()
        for tab in tabs {
            key := ViewCacheKey(tab, "", todayFlag)
            if !viewCache.Has(key)
                buckets[tab] := { key: key, items: [], total: 0 }
        }
        if buckets.Count < 1
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
                    ; ?? 搜索进行中：禁止用空查询 SetView 盖掉搜索结果
                    if !qqSearchOn && !allShown && buckets.Has("all") && buckets["all"].items.Length >= VIEW_PAGE_SIZE {
                        b := buckets["all"]
                        viewCache[b.key] := { items: b.items.Clone(), total: Max(b.total, VIEW_PAGE_SIZE) }
                        SetView("all", "", todayFlag ? "1" : "0")
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
        }
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
            ; Only "全部" unfiltered tiny snapshots are poisoned (copy-before-open).
            ; Sparse tabs (图像/文件/收藏 with <5 items) are real — dropping them
            ; forces a full NDJSON scan on every tab click.
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
                ; 缓存也可能含过期脏数据：有关键字时再滤一遍
                if Trim(viewQuery) != ""
                    FilterClipsInPlaceToQuery()
                ClipLog("SetView cache hit tab=" viewTab " n=" clips.Length " total=" viewTotal)
                viewApplying := false
                if IsObject(wvCore)
                    PushClips(false)
                if qqSearchOn
                    QQPushQuery()
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
        if Trim(viewQuery) != ""
            FilterClipsInPlaceToQuery()
        ClipLog("SetView disk tab=" viewTab " n=" clips.Length " total=" viewTotal)
        CacheCurrentView()
        viewApplying := false
        if IsObject(wvCore)
            PushClips(false)
        if qqSearchOn
            QQPushQuery()
        QQSyncPanelVisibility()
        viewSwitchGuardUntil := A_TickCount + 400
    } finally {
        if myGen = viewApplyGen
            viewApplying := false
    }
}

; 有搜索关键字时，把 clips 收成严格命中（防缓存/竞态脏数据）
FilterClipsInPlaceToQuery(*) {
    global clips, viewTab, viewQuery, viewToday, viewTotal
    q := Trim(String(viewQuery))
    if q = ""
        return
    kept := []
    for c in clips {
        if ItemMatchesView(c, viewTab, q, viewToday)
            kept.Push(c)
    }
    clips := kept
    viewTotal := kept.Length
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
