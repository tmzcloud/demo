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
ICAgIH0KICAgICAgICAuaS10aHVtYi13cmFwLndhaXRpbmcgewogICAgICAgICAgICBtaW4taGVpZ2h0
OiA4OHB4OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGllbnQoOTBkZWcsICNlOGVi
ZjIgMCUsICNmNGY2ZmEgNDUlLCAjZThlYmYyIDEwMCUpOwogICAgICAgICAgICBiYWNrZ3JvdW5kLXNp
emU6IDIwMCUgMTAwJTsKICAgICAgICAgICAgYW5pbWF0aW9uOiB0aHVtYlNoaW1tZXIgMS4wNXMgZWFz
ZS1pbi1vdXQgaW5maW5pdGU7CiAgICAgICAgfQogICAgICAgIEBrZXlmcmFtZXMgdGh1bWJTaGltbWVy
IHsKICAgICAgICAgICAgMCUgeyBiYWNrZ3JvdW5kLXBvc2l0aW9uOiAxMDAlIDA7IH0KICAgICAgICAg
ICAgMTAwJSB7IGJhY2tncm91bmQtcG9zaXRpb246IC0xMDAlIDA7IH0KICAgICAgICB9CiAgICAgICAg
LmktdGh1bWIgeyBtYXgtd2lkdGg6IDEwMCU7IG1heC1oZWlnaHQ6IDE4MHB4OyB3aWR0aDogYXV0bzsg
aGVpZ2h0OiBhdXRvOyBvYmplY3QtZml0OiBjb250YWluOyBkaXNwbGF5OiBibG9jazsgfQogICAgICAg
IC5pLXRodW1iLnRodW1iLWxvYWRpbmcgeyBvcGFjaXR5OiAwOyB3aWR0aDogMXB4OyBoZWlnaHQ6IDFw
eDsgfQoKICAgICAgICAvKiBNZXRhIGJhcjogdGltZSBsZWZ0IHwgZXhwYW5kIGNlbnRlciB8IHRhZ3Mg
cmlnaHQgKi8KICAgICAgICAuaS1tZXRhIHsKICAgICAgICAgICAgZGlzcGxheTogZ3JpZDsKICAgICAg
ICAgICAgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiAxZnIgYXV0byAxZnI7CiAgICAgICAgICAgIGFsaWdu
LWl0ZW1zOiBjZW50ZXI7CiAgICAgICAgICAgIGdhcDogNHB4OwogICAgICAgICAgICBtYXJnaW4tdG9w
OiA0cHg7CiAgICAgICAgICAgIHdpZHRoOiAxMDAlOwogICAgICAgIH0KICAgICAgICAuaS1tZXRhIC5p
LXRpbWUgeyBqdXN0aWZ5LXNlbGY6IHN0YXJ0OyB9CiAgICAgICAgLmktbWV0YS1jZW50ZXIgewogICAg
ICAgICAgICBqdXN0aWZ5LXNlbGY6IGNlbnRlcjsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgYWxp
Z24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7CiAgICAgICAgICAgIGdhcDog
NHB4OwogICAgICAgICAgICBtaW4td2lkdGg6IDFweDsgLyoga2VlcCBjZW50ZXIgY29sdW1uIGV2ZW4g
d2hlbiBleHBhbmQgaXMgaGlkZGVuICovCiAgICAgICAgfQogICAgICAgIC5pLW1ldGEtcmlnaHQgewog
ICAgICAgICAgICBqdXN0aWZ5LXNlbGY6IGVuZDsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgYWxp
Z24taXRlbXM6IGNlbnRlcjsgZ2FwOiA1cHg7IGZsZXgtd3JhcDogbm93cmFwOwogICAgICAgICAgICBq
dXN0aWZ5LWNvbnRlbnQ6IGZsZXgtZW5kOwogICAgICAgICAgICBtaW4td2lkdGg6IDA7CiAgICAgICAg
fQogICAgICAgIC5pLW1ldGEtcmlnaHQudGV4dC1tZXRhIHsKICAgICAgICAgICAgZmxleC13cmFwOiBu
b3dyYXA7CiAgICAgICAgICAgIGdhcDogNHB4OwogICAgICAgIH0KICAgICAgICAuaS1zcmMtdGl0bGUg
ewogICAgICAgICAgICBmb250LXNpemU6IDEwcHg7CiAgICAgICAgICAgIGNvbG9yOiB2YXIoLS10eHQz
KTsKICAgICAgICAgICAgbWF4LXdpZHRoOiAxMWVtOwogICAgICAgICAgICBvdmVyZmxvdzogaGlkZGVu
OwogICAgICAgICAgICB0ZXh0LW92ZXJmbG93OiBlbGxpcHNpczsKICAgICAgICAgICAgd2hpdGUtc3Bh
Y2U6IG5vd3JhcDsKICAgICAgICAgICAgbWluLXdpZHRoOiAwOwogICAgICAgICAgICBsaW5lLWhlaWdo
dDogMS40OwogICAgICAgIH0KICAgICAgICAuaS10aW1lLCAuaS10YWcgeyBmb250LXNpemU6IDEwcHg7
IGNvbG9yOiB2YXIoLS10eHQzKTsgfQogICAgICAgIC5pLXRhZyB7CiAgICAgICAgICAgIGJhY2tncm91
bmQ6ICNmMWYzZjg7IHBhZGRpbmc6IDAgNXB4OyBib3JkZXItcmFkaXVzOiAzcHg7CiAgICAgICAgICAg
IHdoaXRlLXNwYWNlOiBub3dyYXA7IGZsZXgtc2hyaW5rOiAwOyBsaW5lLWhlaWdodDogMS40OwogICAg
ICAgIH0KICAgICAgICAuaS1jaGFycyB7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTBweDsgY29sb3I6
IHZhcigtLXR4dDMpOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZjFmM2Y4OyBwYWRkaW5nOiAwIDVw
eDsgYm9yZGVyLXJhZGl1czogM3B4OwogICAgICAgICAgICBmb250LXZhcmlhbnQtbnVtZXJpYzogdGFi
dWxhci1udW1zOwogICAgICAgICAgICB3aGl0ZS1zcGFjZTogbm93cmFwOwogICAgICAgICAgICBkaXNw
bGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGJhc2VsaW5lOyBnYXA6IDJweDsKICAgICAgICB9
CiAgICAgICAgLmktY2hhcnMgLm4gewogICAgICAgICAgICBkaXNwbGF5OiBpbmxpbmUtYmxvY2s7CiAg
ICAgICAgICAgIG1pbi13aWR0aDogNGNoOwogICAgICAgICAgICB0ZXh0LWFsaWduOiByaWdodDsKICAg
ICAgICAgICAgZm9udC1mYW1pbHk6ICdDYXNjYWRpYSBNb25vJywgJ0NvbnNvbGFzJywgJ1NhcmFzYSBN
b25vIFNDJywgdWktbW9ub3NwYWNlLCBtb25vc3BhY2U7CiAgICAgICAgICAgIGZvbnQtd2VpZ2h0OiA2
MDA7CiAgICAgICAgICAgIGNvbG9yOiB2YXIoLS10eHQyKTsKICAgICAgICB9CiAgICAgICAgLyogc3Jj
LXRpdGxlLXRpcCAqLwogICAgICAgIC5pLXNyYy1pY28sIC5tZy1zcmMgeyBjdXJzb3I6IHBvaW50ZXI7
IH0KICAgICAgICAjc3JjLXRpcCB7CiAgICAgICAgICAgIHBvc2l0aW9uOiBmaXhlZDsgei1pbmRleDog
OTk5OTk7CiAgICAgICAgICAgIG1heC13aWR0aDogbWluKDI4MHB4LCBjYWxjKDEwMHZ3IC0gMTZweCkp
OwogICAgICAgICAgICBwYWRkaW5nOiA2cHggMTBweDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czog
OHB4OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDMyLDM2LDQ4LC45Mik7IGNvbG9yOiAjZmZm
OwogICAgICAgICAgICBmb250LXNpemU6IDEycHg7IGxpbmUtaGVpZ2h0OiAxLjM1OwogICAgICAgICAg
ICBib3gtc2hhZG93OiAwIDZweCAxOHB4IHJnYmEoMCwwLDAsLjIyKTsKICAgICAgICAgICAgcG9pbnRl
ci1ldmVudHM6IG5vbmU7CiAgICAgICAgICAgIG9wYWNpdHk6IDA7IHRyYW5zZm9ybTogdHJhbnNsYXRl
WSg0cHgpOwogICAgICAgICAgICB0cmFuc2l0aW9uOiBvcGFjaXR5IC4ycyBlYXNlLCB0cmFuc2Zvcm0g
LjIycyBjdWJpYy1iZXppZXIoLjIyLDEsLjM2LDEpOwogICAgICAgICAgICB3b3JkLWJyZWFrOiBicmVh
ay13b3JkOwogICAgICAgIH0KICAgICAgICAjc3JjLXRpcC5zaG93IHsgb3BhY2l0eTogMTsgdHJhbnNm
b3JtOiB0cmFuc2xhdGVZKDApOyB9CiAgICAgICAgLmktc3JjLWljbyB7CiAgICAgICAgICAgIHdpZHRo
OiAxNHB4OyBoZWlnaHQ6IDE0cHg7IGZsZXgtc2hyaW5rOiAwOwogICAgICAgICAgICBib3JkZXItcmFk
aXVzOiAycHg7IG9iamVjdC1maXQ6IGNvbnRhaW47CiAgICAgICAgICAgIGRpc3BsYXk6IGJsb2NrOwog
ICAgICAgIH0KICAgICAgICAuaS1udW0gewogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBmbGV4LWRp
cmVjdGlvbjogY29sdW1uOyBhbGlnbi1pdGVtczogZmxleC1lbmQ7CiAgICAgICAgICAgIGp1c3RpZnkt
Y29udGVudDogc3BhY2UtYmV0d2VlbjsKICAgICAgICAgICAgYWxpZ24tc2VsZjogc3RyZXRjaDsKICAg
ICAgICAgICAgZm9udC1zaXplOiAxMHB4OyBjb2xvcjogdmFyKC0tdHh0Myk7IG1pbi13aWR0aDogMTZw
eDsKICAgICAgICAgICAgdGV4dC1hbGlnbjogcmlnaHQ7IGZsZXgtc2hyaW5rOiAwOwogICAgICAgICAg
ICBwYWRkaW5nLXRvcDogMnB4OwogICAgICAgIH0KICAgICAgICAuaS1udW0gLmktc3JjLWljbyB7IHdp
ZHRoOiAxNnB4OyBoZWlnaHQ6IDE2cHg7IG1hcmdpbi10b3A6IGF1dG87IH0KCiAgICAgICAgLmktZXhw
YW5kLWJ0biB7CiAgICAgICAgICAgIGJvcmRlcjogbm9uZTsgYmFja2dyb3VuZDogbm9uZTsgY3Vyc29y
OiBwb2ludGVyOwogICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0Myk7IGZvbnQtc2l6ZTogMTJweDsg
cGFkZGluZzogM3B4IDEwcHg7CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6IDhweDsgZGlzcGxheTog
bm9uZTsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA0cHg7CiAgICAgICAgICAgIHRyYW5zaXRpb246
IGNvbG9yIHZhcigtLXRyKSwgYmFja2dyb3VuZCB2YXIoLS10cik7CiAgICAgICAgICAgIC13ZWJraXQt
YXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICAgICAgbGluZS1o
ZWlnaHQ6IDEuMjsKICAgICAgICB9CiAgICAgICAgLmktZXhwYW5kLWJ0biBzdmcgeyB3aWR0aDogMTRw
eDsgaGVpZ2h0OiAxNHB4OyBmbGV4LXNocmluazogMDsgfQogICAgICAgIC5pLWV4cGFuZC1idG4ub24g
eyBkaXNwbGF5OiBpbmxpbmUtZmxleDsgfQogICAgICAgIC5pLWV4cGFuZC1idG46aG92ZXIgeyBjb2xv
cjogdmFyKC0tYWNjKTsgYmFja2dyb3VuZDogcmdiYSg5MSwxMTUsMjMyLC4wOCk7IH0KICAgICAgICAu
aS1wcmV2LmV4cGFuZGVkLCAuaS1uYW1lLmV4cGFuZGVkIHsKICAgICAgICAgICAgLXdlYmtpdC1saW5l
LWNsYW1wOiB1bnNldDsKICAgICAgICAgICAgZGlzcGxheTogYmxvY2s7CiAgICAgICAgICAgIG92ZXJm
bG93OiBoaWRkZW47CiAgICAgICAgICAgIC8qIOmrmOW6pueUsSBKUyDmjInliJfooajlj6/op4bljLro
rr7lrprvvJrnuqbljaDmlbTooajlsJHkuIDooYwgKi8KICAgICAgICB9CiAgICAgICAgLmktc3JjLXRp
dGxlIHsgZGlzcGxheTogbm9uZSAhaW1wb3J0YW50OyB9CiAgICAgICAgLmktZmlsZS1kZXRhaWwgewog
ICAgICAgICAgICBkaXNwbGF5OiBub25lOwogICAgICAgICAgICBtYXJnaW4tdG9wOiA0cHg7CiAgICAg
ICAgICAgIHBhZGRpbmc6IDA7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IG5vbmU7CiAgICAgICAgICAg
IGJvcmRlcjogbm9uZTsKICAgICAgICB9CiAgICAgICAgLmktZmlsZS1kZXRhaWwub24geyBkaXNwbGF5
OiBibG9jazsgfQogICAgICAgIC5mZC1ibG9jayB7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGZs
ZXgtZGlyZWN0aW9uOiBjb2x1bW47IGdhcDogNnB4OwogICAgICAgIH0KICAgICAgICAuZmQtYmxvY2sg
KyAuZmQtYmxvY2sgeyBtYXJnaW4tdG9wOiA4cHg7IH0KICAgICAgICAuZmQtcGF0aCB7CiAgICAgICAg
ICAgIHdpZHRoOiAxMDAlOwogICAgICAgICAgICBmb250OiA2MDAgMTJweC8xLjU1ICdTZWdvZSBVSSBW
YXJpYWJsZSBUZXh0JywnU2Vnb2UgVUknLCdNaWNyb3NvZnQgWWFIZWkgVUknLHNhbnMtc2VyaWY7CiAg
ICAgICAgICAgIGNvbG9yOiB2YXIoLS10eHQyKTsKICAgICAgICAgICAgbGV0dGVyLXNwYWNpbmc6IC4w
MWVtOwogICAgICAgICAgICB3b3JkLWJyZWFrOiBicmVhay1hbGw7CiAgICAgICAgICAgIHVzZXItc2Vs
ZWN0OiB0ZXh0OwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdp
b246IG5vLWRyYWc7CiAgICAgICAgfQogICAgICAgIC5mZC1wYXRoLmxpdmUgeyBjdXJzb3I6IHBvaW50
ZXI7IH0KICAgICAgICAuZmQtcGF0aC5saXZlOmhvdmVyIHsgY29sb3I6IHZhcigtLWFjYyk7IH0KICAg
ICAgICAuZmQtcGF0aC5kZWFkIHsKICAgICAgICAgICAgY29sb3I6ICM5YWEwYjA7CiAgICAgICAgICAg
IHRleHQtZGVjb3JhdGlvbjogbGluZS10aHJvdWdoOwogICAgICAgICAgICB0ZXh0LWRlY29yYXRpb24t
dGhpY2tuZXNzOiAycHg7CiAgICAgICAgICAgIHRleHQtZGVjb3JhdGlvbi1jb2xvcjogcmdiYSgxNTQs
IDE2MCwgMTc2LCAuNTUpOwogICAgICAgICAgICB0ZXh0LWRlY29yYXRpb24tc2tpcC1pbms6IG5vbmU7
CiAgICAgICAgICAgIGN1cnNvcjogZGVmYXVsdDsKICAgICAgICB9CiAgICAgICAgLmZkLWFjdGlvbnMg
ewogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNv
bnRlbnQ6IGZsZXgtZW5kOwogICAgICAgICAgICBnYXA6IDhweDsgZmxleC13cmFwOiB3cmFwOwogICAg
ICAgIH0KICAgICAgICAuZmQtYnRuIHsKICAgICAgICAgICAgYm9yZGVyOiBub25lOyBiYWNrZ3JvdW5k
OiBub25lOyBjdXJzb3I6IHBvaW50ZXI7CiAgICAgICAgICAgIGNvbG9yOiB2YXIoLS10eHQzKTsgZm9u
dC1zaXplOiAxMHB4OyBmb250LXdlaWdodDogNjAwOwogICAgICAgICAgICBwYWRkaW5nOiAxcHggMnB4
OyBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiAycHg7CiAgICAg
ICAgICAgIHdoaXRlLXNwYWNlOiBub3dyYXA7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjog
bm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICAgICAgdHJhbnNpdGlvbjogY29sb3Ig
dmFyKC0tdHIpOwogICAgICAgIH0KICAgICAgICAuZmQtYnRuOmhvdmVyIHsgY29sb3I6IHZhcigtLWFj
Yyk7IH0KICAgICAgICAuZmQtYnRuLm9rIHsgY29sb3I6ICMxZjdhNTU7IH0KCiAgICAgICAgLyog4pSA
4pSAIENvbnRleHQgbWVudSDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAgKi8KICAg
ICAgICAjY3R4IHsKICAgICAgICAgICAgcG9zaXRpb246IGZpeGVkOyB6LWluZGV4OiA5OTk5OyBtaW4t
d2lkdGg6IDEzMnB4OyBkaXNwbGF5OiBub25lOyBwYWRkaW5nOiA0cHg7CiAgICAgICAgICAgIGJhY2tn
cm91bmQ6ICNmZmY7IGJvcmRlci1yYWRpdXM6IHZhcigtLXIpOyBib3gtc2hhZG93OiAwIDZweCAxNnB4
IHJnYmEoMCwwLDAsLjE0KTsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBh
cHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgIH0KICAgICAgICAjY3R4Lm9uIHsgZGlzcGxheTogYmxv
Y2s7IH0KICAgICAgICAuYy1pdGVtIHsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgYWxpZ24taXRl
bXM6IGNlbnRlcjsgZ2FwOiA3cHg7IHBhZGRpbmc6IDZweCA5cHg7CiAgICAgICAgICAgIGJvcmRlci1y
YWRpdXM6IHZhcigtLXIpOyBjdXJzb3I6IHBvaW50ZXI7IGZvbnQtc2l6ZTogMTFweDsgY29sb3I6IHZh
cigtLXR4dCk7CiAgICAgICAgfQogICAgICAgIC5jLWl0ZW06aG92ZXIgeyBiYWNrZ3JvdW5kOiAjZjJm
NGY5OyB9CiAgICAgICAgLmMtaXRlbS5kYW5nZXIgeyBjb2xvcjogI2ZmN2I5YzsgfQogICAgICAgIC5j
LXNlcCB7IGhlaWdodDogMXB4OyBiYWNrZ3JvdW5kOiAjZWNlZmY1OyBtYXJnaW46IDNweCAwOyB9CiAg
ICAgICAgLmMtaWNvIHsgd2lkdGg6IDE0cHg7IHRleHQtYWxpZ246IGNlbnRlcjsgfQoKICAgICAgICAv
KiDilIDilIAgQ2xlYXIgY29uZmlybSDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAgKi8K
ICAgICAgICAjY2xyLWRsZyB7CiAgICAgICAgICAgIGRpc3BsYXk6IG5vbmU7IHBvc2l0aW9uOiBmaXhl
ZDsgaW5zZXQ6IDA7IHotaW5kZXg6IDEwMDAwOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDIw
LCAyMiwgMzUsIC40Mik7CiAgICAgICAgICAgIGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29u
dGVudDogY2VudGVyOwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1y
ZWdpb246IG5vLWRyYWc7CiAgICAgICAgfQogICAgICAgICNjbHItZGxnLm9uIHsgZGlzcGxheTogZmxl
eDsgfQogICAgICAgIC5jbHItYm94IHsKICAgICAgICAgICAgd2lkdGg6IG1pbigyODBweCwgY2FsYygx
MDAlIC0gMzJweCkpOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZmZmOyBib3JkZXItcmFkaXVzOiAx
MnB4OwogICAgICAgICAgICBib3gtc2hhZG93OiAwIDEycHggMzJweCByZ2JhKDAsMCwwLC4xOCk7CiAg
ICAgICAgICAgIHBhZGRpbmc6IDE2cHggMTZweCAxNHB4OyBjb2xvcjogdmFyKC0tdHh0KTsKICAgICAg
ICB9CiAgICAgICAgLmNsci10aXRsZSB7IGZvbnQtc2l6ZTogMTRweDsgZm9udC13ZWlnaHQ6IDcwMDsg
bWFyZ2luLWJvdHRvbTogNnB4OyB9CiAgICAgICAgLmNsci1kZXNjIHsgZm9udC1zaXplOiAxMXB4OyBj
b2xvcjogdmFyKC0tdHh0Myk7IGxpbmUtaGVpZ2h0OiAxLjU7IG1hcmdpbi1ib3R0b206IDEycHg7IH0K
ICAgICAgICAuY2xyLWNoZWNrIHsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6
IGNlbnRlcjsgZ2FwOiA3cHg7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTJweDsgY29sb3I6IHZhcigt
LXR4dCk7IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICAgICAgdXNlci1zZWxlY3Q6IG5vbmU7IG1hcmdp
bi1ib3R0b206IDE0cHg7CiAgICAgICAgfQogICAgICAgIC5jbHItY2hlY2sgaW5wdXQgewogICAgICAg
ICAgICB3aWR0aDogMTRweDsgaGVpZ2h0OiAxNHB4OyBhY2NlbnQtY29sb3I6IHZhcigtLWFjYyk7IGN1
cnNvcjogcG9pbnRlcjsKICAgICAgICB9CiAgICAgICAgLmNsci1idG5zIHsgZGlzcGxheTogZmxleDsg
Z2FwOiA4cHg7IGp1c3RpZnktY29udGVudDogZmxleC1lbmQ7IH0KICAgICAgICAuY2xyLWJ0bnMgYnV0
dG9uIHsKICAgICAgICAgICAgYm9yZGVyOiBub25lOyBib3JkZXItcmFkaXVzOiA4cHg7IHBhZGRpbmc6
IDdweCAxNHB4OwogICAgICAgICAgICBmb250LXNpemU6IDEycHg7IGN1cnNvcjogcG9pbnRlcjsgZm9u
dC13ZWlnaHQ6IDYwMDsKICAgICAgICAgICAgdHJhbnNpdGlvbjogYmFja2dyb3VuZCB2YXIoLS10ciks
IGNvbG9yIHZhcigtLXRyKTsKICAgICAgICB9CiAgICAgICAgI2Nsci1jYW5jZWwgeyBiYWNrZ3JvdW5k
OiAjZjFmM2Y4OyBjb2xvcjogdmFyKC0tdHh0Mik7IH0KICAgICAgICAjY2xyLWNhbmNlbDpob3ZlciB7
IGJhY2tncm91bmQ6ICNlNmU5ZjI7IH0KICAgICAgICAjY2xyLW9rIHsgYmFja2dyb3VuZDogcmdiYSgy
NTUsMTIzLDE1NiwuMTQpOyBjb2xvcjogI2U4NWE3YTsgfQogICAgICAgICNjbHItb2s6aG92ZXIgeyBi
YWNrZ3JvdW5kOiByZ2JhKDI1NSwxMjMsMTU2LC4yNCk7IH0KCiAgICAgICAgLyog4pSA4pSAIEZpbGUg
cGF0aCB0aXAg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSAICovCiAgICAgICAgI3BhdGgt
dGlwIHsKICAgICAgICAgICAgZGlzcGxheTogbm9uZTsgcG9zaXRpb246IGZpeGVkOyB6LWluZGV4OiAx
MDAwMTsKICAgICAgICAgICAgd2lkdGg6IG1pbigzMjBweCwgY2FsYygxMDB2dyAtIDE2cHgpKTsKICAg
ICAgICAgICAgbWF4LWhlaWdodDogbWluKDI4MHB4LCBjYWxjKDEwMHZoIC0gMjRweCkpOwogICAgICAg
ICAgICBvdmVyZmxvdzogYXV0bzsKICAgICAgICAgICAgcGFkZGluZzogMDsKICAgICAgICAgICAgYmFj
a2dyb3VuZDogbGluZWFyLWdyYWRpZW50KDE2NWRlZywgI2ZmZmZmZiAwJSwgI2Y2ZjhmYyAxMDAlKTsK
ICAgICAgICAgICAgYm9yZGVyOiAxcHggc29saWQgcmdiYSg3MCwgODQsIDEyMCwgLjEpOwogICAgICAg
ICAgICBib3JkZXItcmFkaXVzOiAxMnB4OwogICAgICAgICAgICBib3gtc2hhZG93OgogICAgICAgICAg
ICAgICAgMCA0cHggNnB4IHJnYmEoMzAsIDQwLCA3MCwgLjA0KSwKICAgICAgICAgICAgICAgIDAgMTRw
eCAzNnB4IHJnYmEoMzAsIDQwLCA3MCwgLjE2KTsKICAgICAgICAgICAgY29sb3I6IHZhcigtLXR4dCk7
CiAgICAgICAgICAgIHBvaW50ZXItZXZlbnRzOiBhdXRvOwogICAgICAgICAgICBvcGFjaXR5OiAwOwog
ICAgICAgICAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoNHB4KSBzY2FsZSguOTgpOwogICAgICAgICAg
ICB0cmFuc2l0aW9uOiBvcGFjaXR5IC4xNHMgZWFzZSwgdHJhbnNmb3JtIC4xNHMgZWFzZTsKICAgICAg
ICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAg
ICAgIH0KICAgICAgICAjcGF0aC10aXAub24gewogICAgICAgICAgICBkaXNwbGF5OiBibG9jazsKICAg
ICAgICAgICAgb3BhY2l0eTogMTsKICAgICAgICAgICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKDApIHNj
YWxlKDEpOwogICAgICAgIH0KICAgICAgICAucHQtaGVhZCB7CiAgICAgICAgICAgIGRpc3BsYXk6IGZs
ZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogc3BhY2UtYmV0d2VlbjsKICAg
ICAgICAgICAgZ2FwOiAxMHB4OyBwYWRkaW5nOiAxMHB4IDEycHggOHB4OwogICAgICAgICAgICBib3Jk
ZXItYm90dG9tOiAxcHggc29saWQgcmdiYSg3MCwgODQsIDEyMCwgLjA3KTsKICAgICAgICB9CiAgICAg
ICAgLnB0LXRpdGxlIHsKICAgICAgICAgICAgZm9udC1zaXplOiAxMXB4OyBmb250LXdlaWdodDogNzAw
OyBsZXR0ZXItc3BhY2luZzogLjA0ZW07CiAgICAgICAgICAgIGNvbG9yOiB2YXIoLS10eHQyKTsgdGV4
dC10cmFuc2Zvcm06IHVwcGVyY2FzZTsKICAgICAgICAgICAgZmxleC1zaHJpbms6IDA7CiAgICAgICAg
fQogICAgICAgIC5wdC1oZWFkLWJ0biB7CiAgICAgICAgICAgIGZsZXgtc2hyaW5rOiAwOyBtYXJnaW4t
bGVmdDogYXV0bzsKICAgICAgICAgICAgaGVpZ2h0OiAyMnB4OyBwYWRkaW5nOiAwIDhweDsgZGlzcGxh
eTogaW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogNHB4OwogICAgICAgICAgICBi
b3JkZXI6IDFweCBzb2xpZCByZ2JhKDEwNywxMTIsMTI4LC4yMik7IGJvcmRlci1yYWRpdXM6IDZweDsg
Y3Vyc29yOiBwb2ludGVyOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDEwNywxMTIsMTI4LC4w
Nik7IGNvbG9yOiAjOGE5MGEwOyBmb250LXNpemU6IDExcHg7IGZvbnQtd2VpZ2h0OiA2MDA7CiAgICAg
ICAgICAgIHdoaXRlLXNwYWNlOiBub3dyYXA7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjog
bm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICAgICAgdHJhbnNpdGlvbjogYmFja2dy
b3VuZCB2YXIoLS10ciksIGNvbG9yIHZhcigtLXRyKSwgYm9yZGVyLWNvbG9yIHZhcigtLXRyKTsKICAg
ICAgICB9CiAgICAgICAgLnB0LWhlYWQtYnRuOmhvdmVyIHsKICAgICAgICAgICAgYmFja2dyb3VuZDog
cmdiYSgxMDcsMTEyLDEyOCwuMTIpOyBjb2xvcjogdmFyKC0tdHh0Mik7CiAgICAgICAgICAgIGJvcmRl
ci1jb2xvcjogcmdiYSgxMDcsMTEyLDEyOCwuNCk7CiAgICAgICAgfQogICAgICAgIC5wdC1saXN0IHsg
cGFkZGluZzogNnB4IDhweCA4cHg7IGRpc3BsYXk6IGZsZXg7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47
IGdhcDogNHB4OyB9CiAgICAgICAgLnB0LXJvdyB7CiAgICAgICAgICAgIGRpc3BsYXk6IGdyaWQ7IGdy
aWQtdGVtcGxhdGUtY29sdW1uczogOHB4IDFmcjsgZ2FwOiA4cHg7CiAgICAgICAgICAgIHBhZGRpbmc6
IDhweCA4cHg7IGJvcmRlci1yYWRpdXM6IDhweDsKICAgICAgICAgICAgYmFja2dyb3VuZDogcmdiYSgy
NTUsMjU1LDI1NSwuNyk7CiAgICAgICAgfQogICAgICAgIC5wdC1yb3cuZGVhZCB7IGJhY2tncm91bmQ6
IHJnYmEoMjU1LCAxMjMsIDE1NiwgLjA2KTsgfQogICAgICAgIC5wdC1kb3QgewogICAgICAgICAgICB3
aWR0aDogOHB4OyBoZWlnaHQ6IDhweDsgYm9yZGVyLXJhZGl1czogNTAlOyBtYXJnaW4tdG9wOiA1cHg7
CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICMyZWI0Nzg7IGJveC1zaGFkb3c6IDAgMCAwIDNweCByZ2Jh
KDQ2LCAxODAsIDEyMCwgLjE4KTsKICAgICAgICB9CiAgICAgICAgLnB0LXJvdy5kZWFkIC5wdC1kb3Qg
ewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZTg1YTdhOyBib3gtc2hhZG93OiAwIDAgMCAzcHggcmdi
YSgyMzIsIDkwLCAxMjIsIC4xNik7CiAgICAgICAgfQogICAgICAgIC5wdC1uYW1lIHsKICAgICAgICAg
ICAgZm9udC1zaXplOiAxMnB4OyBmb250LXdlaWdodDogNjUwOyBjb2xvcjogdmFyKC0tdHh0KTsKICAg
ICAgICAgICAgbGluZS1oZWlnaHQ6IDEuMzsgd29yZC1icmVhazogYnJlYWstYWxsOwogICAgICAgIH0K
ICAgICAgICAucHQtcGF0aCB7CiAgICAgICAgICAgIG1hcmdpbi10b3A6IDNweDsKICAgICAgICAgICAg
Zm9udDogMTAuNXB4LzEuNDUgJ0Nhc2NhZGlhIE1vbm8nLCdDb25zb2xhcycsJ01pY3Jvc29mdCBZYUhl
aSBVSScsbW9ub3NwYWNlOwogICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0Mik7IHdvcmQtYnJlYWs6
IGJyZWFrLWFsbDsKICAgICAgICAgICAgdXNlci1zZWxlY3Q6IHRleHQ7CiAgICAgICAgfQogICAgICAg
IC5wdC1wYXRoLmxpdmUgewogICAgICAgICAgICBjb2xvcjogdmFyKC0tYWNjKTsgY3Vyc29yOiBwb2lu
dGVyOwogICAgICAgIH0KICAgICAgICAucHQtcGF0aC5saXZlOmhvdmVyIHsgdGV4dC1kZWNvcmF0aW9u
OiB1bmRlcmxpbmU7IH0KICAgICAgICAucHQtcGF0aC5kZWFkIHsKICAgICAgICAgICAgY29sb3I6ICNj
NDNkNWM7CiAgICAgICAgICAgIHRleHQtZGVjb3JhdGlvbjogbGluZS10aHJvdWdoOwogICAgICAgICAg
ICB0ZXh0LWRlY29yYXRpb24tdGhpY2tuZXNzOiAycHg7CiAgICAgICAgICAgIHRleHQtZGVjb3JhdGlv
bi1jb2xvcjogI2UxMWQ0ODsKICAgICAgICAgICAgY3Vyc29yOiBkZWZhdWx0OwogICAgICAgIH0KICAg
ICAgICAucHQtYWN0aW9ucyB7CiAgICAgICAgICAgIG1hcmdpbi10b3A6IDZweDsKICAgICAgICAgICAg
ZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA2cHg7IGZsZXgtd3JhcDogd3Jh
cDsKICAgICAgICB9CiAgICAgICAgLnB0LWNvcHktYnRuIHsKICAgICAgICAgICAgaGVpZ2h0OiAyMnB4
OyBwYWRkaW5nOiAwIDhweDsgZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7
CiAgICAgICAgICAgIGJvcmRlcjogMXB4IHNvbGlkIHJnYmEoMTA3LDExMiwxMjgsLjIyKTsgYm9yZGVy
LXJhZGl1czogNnB4OyBjdXJzb3I6IHBvaW50ZXI7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEo
MTA3LDExMiwxMjgsLjA2KTsgY29sb3I6ICM4YTkwYTA7IGZvbnQtc2l6ZTogMTFweDsgZm9udC13ZWln
aHQ6IDYwMDsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9u
OiBuby1kcmFnOwogICAgICAgICAgICB0cmFuc2l0aW9uOiBiYWNrZ3JvdW5kIHZhcigtLXRyKSwgY29s
b3IgdmFyKC0tdHIpLCBib3JkZXItY29sb3IgdmFyKC0tdHIpOwogICAgICAgIH0KICAgICAgICAucHQt
Y29weS1idG46aG92ZXIgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDEwNywxMTIsMTI4LC4x
Mik7IGNvbG9yOiB2YXIoLS10eHQyKTsKICAgICAgICAgICAgYm9yZGVyLWNvbG9yOiByZ2JhKDEwNywx
MTIsMTI4LC40KTsKICAgICAgICB9CiAgICAgICAgLnB0LWNvcHktYnRuLm9rIHsKICAgICAgICAgICAg
Y29sb3I6ICMxZjdhNTU7IGJvcmRlci1jb2xvcjogcmdiYSg0NiwgMTgwLCAxMjAsIC4zNSk7CiAgICAg
ICAgICAgIGJhY2tncm91bmQ6IHJnYmEoNDYsIDE4MCwgMTIwLCAuMSk7CiAgICAgICAgfQogICAgICAg
IC5pdG0uaXQtZ3JvdXAgewogICAgICAgICAgICBmbGV4LWRpcmVjdGlvbjogY29sdW1uOwogICAgICAg
ICAgICBhbGlnbi1pdGVtczogc3RyZXRjaDsKICAgICAgICAgICAgZ2FwOiAwOwogICAgICAgICAgICBw
YWRkaW5nOiA2cHggOHB4IDRweDsKICAgICAgICAgICAgY3Vyc29yOiBkZWZhdWx0OwogICAgICAgIH0K
ICAgICAgICAuaXRtLml0LWdyb3VwOmhvdmVyIHsgYmFja2dyb3VuZDogdmFyKC0tY2FyZCk7IH0KICAg
ICAgICAubWctaGVhZCB7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50
ZXI7IGdhcDogNnB4OwogICAgICAgICAgICBmb250LXNpemU6IDExcHg7IGNvbG9yOiB2YXIoLS10eHQz
KTsgZm9udC13ZWlnaHQ6IDYwMDsKICAgICAgICAgICAgcGFkZGluZzogMnB4IDJweCA2cHg7IHVzZXIt
c2VsZWN0OiBub25lOwogICAgICAgIH0KICAgICAgICAubWctaGVhZCAubWctdGFnIHsKICAgICAgICAg
ICAgZGlzcGxheTogaW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7CiAgICAgICAgICAgIGhl
aWdodDogMTZweDsgcGFkZGluZzogMCA2cHg7IGJvcmRlci1yYWRpdXM6IDhweDsKICAgICAgICAgICAg
YmFja2dyb3VuZDogcmdiYSg5MSwxMTUsMjMyLC4xMik7IGNvbG9yOiB2YXIoLS1hY2MpOyBmb250LXNp
emU6IDEwcHg7CiAgICAgICAgfQogICAgICAgIC5tZy1yb3cgewogICAgICAgICAgICBwYWRkaW5nOiA3
cHggNnB4OyBtYXJnaW4tYm90dG9tOiAzcHg7CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6IDVweDsg
Y3Vyc29yOiBwb2ludGVyOwogICAgICAgICAgICBib3JkZXI6IDFweCBzb2xpZCB0cmFuc3BhcmVudDsK
ICAgICAgICAgICAgdHJhbnNpdGlvbjogYmFja2dyb3VuZCAuMTJzIGVhc2UsIGJvcmRlci1jb2xvciAu
MTJzIGVhc2U7CiAgICAgICAgfQogICAgICAgIC5tZy1yb3c6aG92ZXIgeyBiYWNrZ3JvdW5kOiB2YXIo
LS1jYXJkLWgpOyB9CiAgICAgICAgLm1nLXJvdy5zZWwgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAj
ZWRmMWZmOwogICAgICAgICAgICBib3JkZXItY29sb3I6IHJnYmEoOTEsMTE1LDIzMiwuMzUpOwogICAg
ICAgICAgICBib3gtc2hhZG93OiAwIDAgMCAxcHggcmdiYSg5MSwxMTUsMjMyLC4yNSk7CiAgICAgICAg
fQogICAgICAgIC5tZy1yb3cubXVsdGkgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZWVmMmZmOwog
ICAgICAgICAgICBib3JkZXItY29sb3I6IHJnYmEoOTEsMTE1LDIzMiwuNDUpOwogICAgICAgIH0KICAg
ICAgICAubWctdGl0bGUgewogICAgICAgICAgICBmb250LXNpemU6IDEzcHg7IGZvbnQtd2VpZ2h0OiA2
MDA7IGNvbG9yOiB2YXIoLS1hY2MpOwogICAgICAgICAgICBtYXJnaW4tYm90dG9tOiAycHg7IGxpbmUt
aGVpZ2h0OiAxLjM1OwogICAgICAgICAgICBkaXNwbGF5OiAtd2Via2l0LWJveDsgLXdlYmtpdC1ib3gt
b3JpZW50OiB2ZXJ0aWNhbDsgLXdlYmtpdC1saW5lLWNsYW1wOiAyOwogICAgICAgICAgICBvdmVyZmxv
dzogaGlkZGVuOyB3b3JkLWJyZWFrOiBicmVhay13b3JkOwogICAgICAgIH0KICAgICAgICAubWctYm9k
eSB7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTIuNXB4OyBmb250LXdlaWdodDogNTAwOyBjb2xvcjog
dmFyKC0tdHh0KTsKICAgICAgICAgICAgd2hpdGUtc3BhY2U6IHByZS13cmFwOyB3b3JkLWJyZWFrOiBi
cmVhay1hbGw7CiAgICAgICAgICAgIGRpc3BsYXk6IC13ZWJraXQtYm94OyAtd2Via2l0LWJveC1vcmll
bnQ6IHZlcnRpY2FsOyAtd2Via2l0LWxpbmUtY2xhbXA6IDQ7CiAgICAgICAgICAgIG92ZXJmbG93OiBo
aWRkZW47IGxpbmUtaGVpZ2h0OiAxLjQ7CiAgICAgICAgfQogICAgICAgIC5tZy1ib2R5LmltZyB7IGNv
bG9yOiB2YXIoLS10eHQyKTsgfQogICAgICAgIC5tZy1yb3ctdG9wIHsKICAgICAgICAgICAgZGlzcGxh
eTogZmxleDsgYWxpZ24taXRlbXM6IGZsZXgtc3RhcnQ7IGdhcDogOHB4OwogICAgICAgIH0KICAgICAg
ICAubWctcm93LW1haW4geyBmbGV4OiAxOyBtaW4td2lkdGg6IDA7IH0KICAgICAgICAubWctc3JjIHsK
ICAgICAgICAgICAgd2lkdGg6IDE4cHg7IGhlaWdodDogMThweDsgZmxleC1zaHJpbms6IDA7IG1hcmdp
bi10b3A6IDJweDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogM3B4OyBvYmplY3QtZml0OiBjb250
YWluOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDAsMCwwLC4wNCk7CiAgICAgICAgfQogICAg
ICAgIC5pLWZhdi10aXRsZSB7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTNweDsgZm9udC13ZWlnaHQ6
IDYwMDsgY29sb3I6IHZhcigtLWFjYyk7CiAgICAgICAgICAgIG1hcmdpbjogMCAwIDNweDsgbGluZS1o
ZWlnaHQ6IDEuMzU7CiAgICAgICAgICAgIGRpc3BsYXk6IC13ZWJraXQtYm94OyAtd2Via2l0LWJveC1v
cmllbnQ6IHZlcnRpY2FsOyAtd2Via2l0LWxpbmUtY2xhbXA6IDI7CiAgICAgICAgICAgIG92ZXJmbG93
OiBoaWRkZW47IHdvcmQtYnJlYWs6IGJyZWFrLXdvcmQ7CiAgICAgICAgfQogICAgICAgICN0aXRsZS1k
bGcgewogICAgICAgICAgICBkaXNwbGF5OiBub25lOyBwb3NpdGlvbjogZml4ZWQ7IGluc2V0OiAwOyB6
LWluZGV4OiAxMDA7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoMTUsMTgsMjgsLjM1KTsKICAg
ICAgICAgICAgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7CiAgICAg
ICAgfQogICAgICAgICN0aXRsZS1kbGcub24geyBkaXNwbGF5OiBmbGV4OyB9CiAgICAgICAgI3RpdGxl
LWRsZyAudGl0bGUtYm94IHsKICAgICAgICAgICAgd2lkdGg6IDI2MHB4OyBwYWRkaW5nOiAxNnB4IDE2
cHggMTJweDsKICAgICAgICAgICAgYmFja2dyb3VuZDogdmFyKC0tY2FyZCk7IGJvcmRlci1yYWRpdXM6
IDEwcHg7CiAgICAgICAgICAgIGJveC1zaGFkb3c6IDAgOHB4IDI4cHggcmdiYSgwLDAsMCwuMTgpOwog
ICAgICAgIH0KICAgICAgICAjdGl0bGUtaW5wdXQgewogICAgICAgICAgICB3aWR0aDogMTAwJTsgYm94
LXNpemluZzogYm9yZGVyLWJveDsgbWFyZ2luOiA4cHggMCAxMnB4OwogICAgICAgICAgICBoZWlnaHQ6
IDMycHg7IHBhZGRpbmc6IDAgMTBweDsgYm9yZGVyLXJhZGl1czogNnB4OwogICAgICAgICAgICBib3Jk
ZXI6IDFweCBzb2xpZCAjZDVkYWU2OyBiYWNrZ3JvdW5kOiAjZmZmOyBjb2xvcjogdmFyKC0tdHh0KTsK
ICAgICAgICAgICAgZm9udC1zaXplOiAxM3B4OyBvdXRsaW5lOiBub25lOwogICAgICAgIH0KICAgICAg
ICAjdGl0bGUtaW5wdXQ6Zm9jdXMgeyBib3JkZXItY29sb3I6IHZhcigtLWFjYyk7IH0KCiAgICAKICAg
ICAgICAvKiB1aS1ncmF5LWJnLXYxICovCiAgICAgICAgOnJvb3QgewogICAgICAgICAgICAtLWJnOiAj
ZTRlN2VlICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgIGh0bWwsIGJvZHkgewogICAgICAgICAg
ICBiYWNrZ3JvdW5kOiAjZTRlN2VlICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgICNhcHAgewog
ICAgICAgICAgICBiYWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGllbnQoMTgwZGVnLCAjZTllY2YzIDAlLCAj
ZTBlNGVjIDEwMCUpICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgICNoZHIgewogICAgICAgICAg
ICBiYWNrZ3JvdW5kOiAjZTJlNmVlICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgICN0YWJzIHsK
ICAgICAgICAgICAgYmFja2dyb3VuZDogI2UyZTZlZSAhaW1wb3J0YW50OwogICAgICAgIH0KICAgICAg
ICAjbGlzdCwgI2VtcHR5LCAjc2tlbCwgI2hkci1ncm93LCAjc2VhcmNoLXdyYXAgewogICAgICAgICAg
ICBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudCAhaW1wb3J0YW50OwogICAgICAgIH0KICAgICAgICAjc2Vh
cmNoLWJveCB7CiAgICAgICAgICAgIHRyYW5zZm9ybS1vcmlnaW46IHJpZ2h0IGNlbnRlcjsKICAgICAg
ICAgICAgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAg
Lml0bSwgLm1nLCAubWctcm93LCAubWVyZ2UtZ3JvdXAgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAj
ZmZmZmZmICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgIC5pdG06aG92ZXIgewogICAgICAgICAg
ICBiYWNrZ3JvdW5kOiAjZjhmOWZjICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgCiAgICAgICAgLyog
c2VsLXRpbnQtYmx1ZS12MSAqLwogICAgICAgIC5pdG0uc2VsLAogICAgICAgIC5tZy1yb3cuc2VsLAog
ICAgICAgIC5pdG0ubXVsdGksCiAgICAgICAgLm1nLXJvdy5tdWx0aSwKICAgICAgICAuaXRtLm11bHRp
LnNlbCwKICAgICAgICAuaXQtZ3JvdXAuc2VsLAogICAgICAgIC5pdC1ncm91cC5tdWx0aSB7CiAgICAg
ICAgICAgIGJhY2tncm91bmQ6ICNlOGVmZmYgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgLml0
bS5zZWw6aG92ZXIsCiAgICAgICAgLml0bS5tdWx0aTpob3ZlciwKICAgICAgICAubWctcm93LnNlbDpo
b3ZlciwKICAgICAgICAubWctcm93Lm11bHRpOmhvdmVyIHsKICAgICAgICAgICAgYmFja2dyb3VuZDog
I2RkZTZmZiAhaW1wb3J0YW50OwogICAgICAgIH0KICAgIAogICAgICAgIC8qIGhvdmVyLWdyZWVuLXJp
c2UtdjIgKi8KICAgICAgICAvKiBob3Zlci1hY2NlbnQtcmlzZS12MyAqLwogICAgICAgIC5pdG0geyBw
b3NpdGlvbjogcmVsYXRpdmUgIWltcG9ydGFudDsgb3ZlcmZsb3c6IGhpZGRlbiAhaW1wb3J0YW50OyB9
CiAgICAgICAgLml0bTo6YmVmb3JlIHsKICAgICAgICAgICAgY29udGVudDogIiIgIWltcG9ydGFudDsK
ICAgICAgICAgICAgcG9zaXRpb246IGFic29sdXRlICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIGxlZnQ6
IDAgIWltcG9ydGFudDsgcmlnaHQ6IDAgIWltcG9ydGFudDsgYm90dG9tOiAwICFpbXBvcnRhbnQ7CiAg
ICAgICAgICAgIGhlaWdodDogMCAhaW1wb3J0YW50OwogICAgICAgICAgICBwb2ludGVyLWV2ZW50czog
bm9uZSAhaW1wb3J0YW50OwogICAgICAgICAgICB6LWluZGV4OiAwICFpbXBvcnRhbnQ7CiAgICAgICAg
ICAgIGJvcmRlci1yYWRpdXM6IDAgMCB2YXIoLS1yLCA0cHgpIHZhcigtLXIsIDRweCkgIWltcG9ydGFu
dDsKICAgICAgICAgICAgYmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50KHRvIHRvcCwKICAgICAgICAg
ICAgICAgIHJnYmEoOTEsIDExNSwgMjMyLCAuMzIpIDAlLAogICAgICAgICAgICAgICAgcmdiYSg5MSwg
MTE1LCAyMzIsIC4xMikgNTUlLAogICAgICAgICAgICAgICAgcmdiYSg5MSwgMTE1LCAyMzIsIDApIDEw
MCUpICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIHRyYW5zaXRpb246IGhlaWdodCAuMzRzIGN1YmljLWJl
emllciguMjIsIDEsIC4zNiwgMSkgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgLml0bTpob3Zl
cjo6YmVmb3JlIHsgaGVpZ2h0OiAzMy4zMzMlICFpbXBvcnRhbnQ7IH0KICAgICAgICAuaXRtOjphZnRl
ciB7CiAgICAgICAgICAgIGNvbnRlbnQ6ICIiICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIHBvc2l0aW9u
OiBhYnNvbHV0ZSAhaW1wb3J0YW50OwogICAgICAgICAgICBsZWZ0OiAwICFpbXBvcnRhbnQ7IHJpZ2h0
OiAwICFpbXBvcnRhbnQ7IGJvdHRvbTogMCAhaW1wb3J0YW50OwogICAgICAgICAgICBoZWlnaHQ6IDJw
eCAhaW1wb3J0YW50OwogICAgICAgICAgICBwb2ludGVyLWV2ZW50czogbm9uZSAhaW1wb3J0YW50Owog
ICAgICAgICAgICB6LWluZGV4OiAxICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJn
YmEoOTEsIDExNSwgMjMyLCAuOTIpICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6
IDFweCAhaW1wb3J0YW50OwogICAgICAgICAgICB0cmFuc2Zvcm06IHNjYWxlWCgwKSAhaW1wb3J0YW50
OwogICAgICAgICAgICB0cmFuc2Zvcm0tb3JpZ2luOiBjZW50ZXIgIWltcG9ydGFudDsKICAgICAgICAg
ICAgdHJhbnNpdGlvbjogdHJhbnNmb3JtIC4zcyBjdWJpYy1iZXppZXIoLjIyLCAxLCAuMzYsIDEpICFp
bXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgIC5pdG06aG92ZXI6OmFmdGVyIHsKICAgICAgICAgICAg
dHJhbnNmb3JtOiBzY2FsZVgoMSkgIWltcG9ydGFudDsKICAgICAgICAgICAgYmFja2dyb3VuZDogcmdi
YSg5MSwgMTE1LCAyMzIsIC45NSkgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgLml0bSA+ICog
eyBwb3NpdGlvbjogcmVsYXRpdmU7IHotaW5kZXg6IDI7IH0KICAgICAgICAgICAgLyogd2hpdGUtcGFu
ZWwtYm9yZGVyOiBvdXRlciBlZGdlIGxpbmUgcmVtb3ZlZCAqLwogICAgICAgICNhcHAgewogICAgICAg
ICAgICBib3JkZXI6IG5vbmUgIWltcG9ydGFudDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogMCAh
aW1wb3J0YW50OwogICAgICAgICAgICBib3gtc2l6aW5nOiBib3JkZXItYm94ICFpbXBvcnRhbnQ7CiAg
ICAgICAgICAgIG92ZXJmbG93OiBoaWRkZW4gIWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgLml0
bSwgLm1nLCAubWctcm93LCAubWVyZ2UtZ3JvdXAgewogICAgICAgICAgICBib3JkZXI6IDFweCBzb2xp
ZCAjZmZmZmZmICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgPC9zdHlsZT4KPC9oZWFkPgo8Ym9keT4K
PGRpdiBpZD0iYXBwIj4KICAgIDxkaXYgaWQ9ImhkciI+CiAgICAgICAgPGRpdiBpZD0iaGVhcnQiPgog
ICAgICAgICAgICA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJy
ZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44IgogICAgICAgICAgICAgICAgIHN0cm9rZS1saW5lY2Fw
PSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI+CiAgICAgICAgICAgICAgICA8cmVjdCB4PSI5
IiB5PSIyIiB3aWR0aD0iNiIgaGVpZ2h0PSI0IiByeD0iMSIvPgogICAgICAgICAgICAgICAgPHBhdGgg
ZD0iTTE2IDRoMmEyIDIgMCAwIDEgMiAydjE0YTIgMiAwIDAgMS0yIDJINmEyIDIgMCAwIDEtMi0yVjZh
MiAyIDAgMCAxIDItMmgyIi8+CiAgICAgICAgICAgICAgICA8cGF0aCBkPSJNOSAxMmg2TTkgMTZoNCIv
PgogICAgICAgICAgICA8L3N2Zz4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGlkPSJoZHItZ3Jv
dyI+PC9kaXY+CiAgICAgICAgPGJ1dHRvbiBpZD0iYnRuLWxvY2F0ZSIgdHlwZT0iYnV0dG9uIiB0aXRs
ZT0i5a6a5L2N5Yiw5LiK5qyh5L2/55So55qE5p2h55uuIiBkaXNhYmxlZD4KICAgICAgICAgICAgPHN2
ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJv
a2Utd2lkdGg9IjIiCiAgICAgICAgICAgICAgICAgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2Ut
bGluZWpvaW49InJvdW5kIj4KICAgICAgICAgICAgICAgIDxjaXJjbGUgY3g9IjEyIiBjeT0iMTIiIHI9
IjgiLz4KICAgICAgICAgICAgICAgIDxjaXJjbGUgY3g9IjEyIiBjeT0iMTIiIHI9IjMuNSIvPgogICAg
ICAgICAgICA8L3N2Zz4KICAgICAgICA8L2J1dHRvbj4KICAgICAgICA8ZGl2IGlkPSJzZWFyY2gtd3Jh
cCI+CiAgICAgICAgICAgIDxidXR0b24gaWQ9ImJ0bi1zZWFyY2giIHR5cGU9ImJ1dHRvbiIgdGl0bGU9
IuaQnOe0oiI+CiAgICAgICAgICAgICAgICA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9u
ZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMiIKICAgICAgICAgICAgICAgICAg
ICAgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIj4KICAgICAgICAg
ICAgICAgICAgICA8Y2lyY2xlIGN4PSIxMSIgY3k9IjExIiByPSI3Ii8+CiAgICAgICAgICAgICAgICAg
ICAgPHBhdGggZD0iTTIwIDIwbC0zLjUtMy41Ii8+CiAgICAgICAgICAgICAgICA8L3N2Zz4KICAgICAg
ICAgICAgPC9idXR0b24+CiAgICAgICAgICAgIDxkaXYgaWQ9InNlYXJjaC1ib3giPgogICAgICAgICAg
ICAgICAgPGJ1dHRvbiBpZD0iYnRuLXRvZGF5IiB0eXBlPSJidXR0b24iPuW9k+WkqTwvYnV0dG9uPgog
ICAgICAgICAgICAgICAgPGlucHV0IGlkPSJzZWFyY2giIHR5cGU9InRleHQiIHBsYWNlaG9sZGVyPSLm
kJzntKLigKYg56m65qC85YiG6K+N6aG75ZCM5pe25YyF5ZCrIMK3IGF8YiDliIbmrrUiIGF1dG9jb21w
bGV0ZT0ib2ZmIiBzcGVsbGNoZWNrPSJmYWxzZSI+CiAgICAgICAgICAgICAgICA8YnV0dG9uIGlkPSJz
ZWFyY2gtY2xyIiB0eXBlPSJidXR0b24iPuKclTwvYnV0dG9uPgogICAgICAgICAgICA8L2Rpdj4KICAg
ICAgICA8L2Rpdj4KICAgICAgICA8YnV0dG9uIGlkPSJidG4tcGluIiB0eXBlPSJidXR0b24iIHRpdGxl
PSLpkonlnKjlsY/luZXkuIoiPgogICAgICAgICAgICA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmls
bD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMiIKICAgICAgICAgICAg
ICAgICBzdHJva2UtbGluZWpvaW49InJvdW5kIiBzdHJva2UtbGluZWNhcD0icm91bmQiPgogICAgICAg
ICAgICAgICAgPGxpbmUgeDE9IjEyIiB5MT0iMTciIHgyPSIxMiIgeTI9IjIyIi8+CiAgICAgICAgICAg
ICAgICA8cGF0aCBkPSJNNSAxN2gxNHYtMS43NmEyIDIgMCAwIDAtMS4xMS0xLjc5bC0xLjc4LS45QTIg
MiAwIDAgMSAxNSAxMC43NlY2aDFhMiAyIDAgMCAwIDAtNEg4YTIgMiAwIDAgMCAwIDRoMXY0Ljc2YTIg
MiAwIDAgMS0xLjExIDEuNzlsLTEuNzguOUEyIDIgMCAwIDAgNSAxNS4yNFoiLz4KICAgICAgICAgICAg
PC9zdmc+CiAgICAgICAgPC9idXR0b24+CiAgICA8L2Rpdj4KCiAgICA8ZGl2IGlkPSJ0YWJzIj4KICAg
ICAgICA8ZGl2IGlkPSJ0YWItaW5rIiBhcmlhLWhpZGRlbj0idHJ1ZSI+PC9kaXY+CiAgICAgICAgPGRp
diBjbGFzcz0idGFiIG9uIiBkYXRhLXRhYj0iYWxsIj7lhajpg6g8L2Rpdj4KICAgICAgICA8ZGl2IGNs
YXNzPSJ0YWIiIGRhdGEtdGFiPSJ0ZXh0Ij7mlofmnKw8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJ0
YWIiIGRhdGEtdGFiPSJpbWFnZSI+5Zu+5YOPPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0idGFiIiBk
YXRhLXRhYj0iZmlsZSI+5paH5Lu2PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0idGFiIiBkYXRhLXRh
Yj0icGlubmVkIj7mlLbol48gPHNwYW4gY2xhc3M9ImJhZGdlIiBpZD0icGluLWNudCIgc3R5bGU9ImRp
c3BsYXk6bm9uZSI+MDwvc3Bhbj48L2Rpdj4KICAgICAgICA8ZGl2IGlkPSJ0YWItYWN0aW9ucyI+CiAg
ICAgICAgICAgIDxidXR0b24gaWQ9Im11bHRpLWNudCIgdHlwZT0iYnV0dG9uIiB0aXRsZT0i5Y+W5raI
5aSa6YCJIj4wPC9idXR0b24+CiAgICAgICAgICAgIDxzcGFuIGlkPSJiYXItdHh0Ij4wPC9zcGFuPgog
ICAgICAgICAgICA8YnV0dG9uIGlkPSJidG4tY2xyIiB0eXBlPSJidXR0b24iIHRpdGxlPSLmuIXnqbrl
joblj7IiPgogICAgICAgICAgICAgICAgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUi
IHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIiCiAgICAgICAgICAgICAgICAgICAg
IHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI+CiAgICAgICAgICAg
ICAgICAgICAgPHBvbHlsaW5lIHBvaW50cz0iMyA2IDUgNiAyMSA2Ii8+CiAgICAgICAgICAgICAgICAg
ICAgPHBhdGggZD0iTTE5IDZsLTEgMTRhMiAyIDAgMCAxLTIgMkg4YTIgMiAwIDAgMS0yLTJMNSA2Ii8+
CiAgICAgICAgICAgICAgICAgICAgPHBhdGggZD0iTTEwIDExdjZNMTQgMTF2Nk05IDZWNGg2djIiLz4K
ICAgICAgICAgICAgICAgIDwvc3ZnPgogICAgICAgICAgICA8L2J1dHRvbj4KICAgICAgICA8L2Rpdj4K
ICAgIDwvZGl2PgoKICAgIDxkaXYgaWQ9Imxpc3QiPgogICAgICAgIDxkaXYgaWQ9InNrZWwiIGFyaWEt
aGlkZGVuPSJ0cnVlIj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0ic2stcm93Ij48ZGl2IGNsYXNzPSJz
ay1pY28iPjwvZGl2PjxkaXYgY2xhc3M9InNrLWJvZHkiPjxkaXYgY2xhc3M9InNrLWxpbmUgbWlkIj48
L2Rpdj48ZGl2IGNsYXNzPSJzay1saW5lIHNob3J0Ij48L2Rpdj48L2Rpdj48L2Rpdj4KICAgICAgICAg
ICAgPGRpdiBjbGFzcz0ic2stcm93Ij48ZGl2IGNsYXNzPSJzay1pY28iPjwvZGl2PjxkaXYgY2xhc3M9
InNrLWJvZHkiPjxkaXYgY2xhc3M9InNrLWxpbmUiPjwvZGl2PjxkaXYgY2xhc3M9InNrLWxpbmUgbWlk
Ij48L2Rpdj48L2Rpdj48L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0ic2stcm93Ij48ZGl2IGNs
YXNzPSJzay1pY28iPjwvZGl2PjxkaXYgY2xhc3M9InNrLWJvZHkiPjxkaXYgY2xhc3M9InNrLWxpbmUg
bWlkIj48L2Rpdj48ZGl2IGNsYXNzPSJzay1saW5lIHNob3J0Ij48L2Rpdj48L2Rpdj48L2Rpdj4KICAg
ICAgICAgICAgPGRpdiBjbGFzcz0ic2stcm93Ij48ZGl2IGNsYXNzPSJzay1pY28iPjwvZGl2PjxkaXYg
Y2xhc3M9InNrLWJvZHkiPjxkaXYgY2xhc3M9InNrLWxpbmUiPjwvZGl2PjxkaXYgY2xhc3M9InNrLWxp
bmUgbWlkIj48L2Rpdj48L2Rpdj48L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0ic2stcm93Ij48
ZGl2IGNsYXNzPSJzay1pY28iPjwvZGl2PjxkaXYgY2xhc3M9InNrLWJvZHkiPjxkaXYgY2xhc3M9InNr
LWxpbmUgbWlkIj48L2Rpdj48ZGl2IGNsYXNzPSJzay1saW5lIHNob3J0Ij48L2Rpdj48L2Rpdj48L2Rp
dj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0ic2stcm93Ij48ZGl2IGNsYXNzPSJzay1pY28iPjwvZGl2
PjxkaXYgY2xhc3M9InNrLWJvZHkiPjxkaXYgY2xhc3M9InNrLWxpbmUiPjwvZGl2PjxkaXYgY2xhc3M9
InNrLWxpbmUgc2hvcnQiPjwvZGl2PjwvZGl2PjwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxk
aXYgaWQ9ImVtcHR5Ij4KICAgICAgICAgICAgPGRpdiBjbGFzcz0iZS10eHQiIGlkPSJlbXB0eS10eHQi
PuaaguaXoOiusOW9le+8jOWkjeWItuWQjuiHquWKqOWHuueOsDwvZGl2PgogICAgICAgIDwvZGl2Pgog
ICAgPC9kaXY+CiAgICA8YnV0dG9uIGlkPSJidG4tdG9wIiB0eXBlPSJidXR0b24iIHRpdGxlPSLlm57l
iLDpobbpg6giIGFyaWEtbGFiZWw9IuWbnuWIsOmhtumDqCI+CiAgICAgICAgPHN2ZyB2aWV3Qm94PSIw
IDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIu
MiIKICAgICAgICAgICAgIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3Vu
ZCI+CiAgICAgICAgICAgIDxwYXRoIGQ9Ik0xMiAxOVY1Ii8+CiAgICAgICAgICAgIDxwYXRoIGQ9Ik01
IDEybDctNyA3IDciLz4KICAgICAgICA8L3N2Zz4KICAgIDwvYnV0dG9uPgo8L2Rpdj4KCjxkaXYgaWQ9
ImN0eCI+CiAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0iIGlkPSJjLWNvcHkiPjxzcGFuIGNsYXNzPSJjLWlj
byI+4o6YPC9zcGFuPuWkjeWItjwvZGl2PgogICAgPGRpdiBjbGFzcz0iYy1pdGVtIiBpZD0iYy1wYXN0
ZSI+PHNwYW4gY2xhc3M9ImMtaWNvIj7ij448L3NwYW4+57KY6LS0PC9kaXY+CiAgICA8ZGl2IGNsYXNz
PSJjLXNlcCI+PC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0iIGlkPSJjLXBpbiI+PHNwYW4gY2xh
c3M9ImMtaWNvIj7imIU8L3NwYW4+5pS26JePPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0iIGlk
PSJjLXRpdGxlIiBzdHlsZT0iZGlzcGxheTpub25lIj48c3BhbiBjbGFzcz0iYy1pY28iPuKcjjwvc3Bh
bj7orr7nva7moIfpopg8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImMtaXRlbSIgaWQ9ImMtbWVyZ2UiIHN0
eWxlPSJkaXNwbGF5Om5vbmUiPjxzcGFuIGNsYXNzPSJjLWljbyI+4qeJPC9zcGFuPuWQiOW5tjwvZGl2
PgogICAgPGRpdiBjbGFzcz0iYy1pdGVtIiBpZD0iYy11bm1lcmdlIiBzdHlsZT0iZGlzcGxheTpub25l
Ij48c3BhbiBjbGFzcz0iYy1pY28iPuKHhDwvc3Bhbj7lj5bmtojlkIjlubY8L2Rpdj4KICAgIDxkaXYg
Y2xhc3M9ImMtaXRlbSIgaWQ9ImMtdG9wIj48c3BhbiBjbGFzcz0iYy1pY28iPuKGkTwvc3Bhbj7np7vl
iLDpobbpg6g8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImMtaXRlbSIgaWQ9ImMtY2xlYXItcGFzdGVkIiBz
dHlsZT0iZGlzcGxheTpub25lIj48c3BhbiBjbGFzcz0iYy1pY28iPuKckzwvc3Bhbj7muIXpmaTnirbm
gIE8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImMtc2VwIj48L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImMtaXRl
bSBkYW5nZXIiIGlkPSJjLWRlbCI+PHNwYW4gY2xhc3M9ImMtaWNvIj7inJU8L3NwYW4+5Yig6ZmkPC9k
aXY+CjwvZGl2PgoKPGRpdiBpZD0iY2xyLWRsZyI+CiAgICA8ZGl2IGNsYXNzPSJjbHItYm94IiByb2xl
PSJkaWFsb2ciIGFyaWEtbW9kYWw9InRydWUiPgogICAgICAgIDxkaXYgY2xhc3M9ImNsci10aXRsZSIg
aWQ9ImNsci10aXRsZSI+56Gu6K6k5riF56m677yfPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iY2xy
LWRlc2MiIGlkPSJjbHItZGVzYyI+6buY6K6k5LuF5riF56m65b2T5aSp5YaF5a6544CCPC9kaXY+CiAg
ICAgICAgPGxhYmVsIGNsYXNzPSJjbHItY2hlY2siIGZvcj0iY2xyLWFsbCI+CiAgICAgICAgICAgIDxp
bnB1dCB0eXBlPSJjaGVja2JveCIgaWQ9ImNsci1hbGwiPgogICAgICAgICAgICA8c3Bhbj7muIXnqbrm
iYDmnIk8L3NwYW4+CiAgICAgICAgPC9sYWJlbD4KICAgICAgICA8ZGl2IGNsYXNzPSJjbHItYnRucyI+
CiAgICAgICAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBpZD0iY2xyLWNhbmNlbCI+5Y+W5raIPC9i
dXR0b24+CiAgICAgICAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBpZD0iY2xyLW9rIj7muIXnqbo8
L2J1dHRvbj4KICAgICAgICA8L2Rpdj4KICAgIDwvZGl2Pgo8L2Rpdj4KCjxkaXYgaWQ9InRpdGxlLWRs
ZyI+CiAgICA8ZGl2IGNsYXNzPSJ0aXRsZS1ib3giIHJvbGU9ImRpYWxvZyIgYXJpYS1tb2RhbD0idHJ1
ZSI+CiAgICAgICAgPGRpdiBjbGFzcz0iY2xyLXRpdGxlIj7orr7nva7moIfpopg8L2Rpdj4KICAgICAg
ICA8ZGl2IGNsYXNzPSJjbHItZGVzYyI+5qCH6aKY5Y+v6KKr5pCc57Si5om+5Yiw77yM5LuF55So5LqO
5pS26JeP5pW055CG44CCPC9kaXY+CiAgICAgICAgPGlucHV0IGlkPSJ0aXRsZS1pbnB1dCIgdHlwZT0i
dGV4dCIgbWF4bGVuZ3RoPSI4MCIgcGxhY2Vob2xkZXI9Iue7mei/meadoeaUtuiXj+i1t+S4quWQjeWt
l+KApiIgYXV0b2NvbXBsZXRlPSJvZmYiIHNwZWxsY2hlY2s9ImZhbHNlIj4KICAgICAgICA8ZGl2IGNs
YXNzPSJjbHItYnRucyI+CiAgICAgICAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBpZD0idGl0bGUt
Y2FuY2VsIj7lj5bmtog8L2J1dHRvbj4KICAgICAgICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGlk
PSJ0aXRsZS1vayI+5L+d5a2YPC9idXR0b24+CiAgICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KPC9kaXY+
CjxkaXYgaWQ9InBhdGgtdGlwIiBhcmlhLWhpZGRlbj0idHJ1ZSI+PC9kaXY+Cgo8c2NyaXB0PgovKiBz
a2VsLWZhaWxzYWZlOiBvbmx5IGlmIG1haW4gVUkgc2NyaXB0IG5ldmVyIGJvb3RlZCDigJRuZXZlciBp
bnZlbnQgZW1wdHktc3RhdGUgKi8KKGZ1bmN0aW9uKCl7CiAgc2V0VGltZW91dCgoKSA9PiB7CiAgICB0
cnkgewogICAgICBpZiAod2luZG93Ll9fdWlCb290ZWQpIHJldHVybjsKICAgICAgdmFyIGFwcCA9IGRv
Y3VtZW50LmdldEVsZW1lbnRCeUlkKCdhcHAnKTsKICAgICAgaWYgKGFwcCkgYXBwLmNsYXNzTGlzdC5y
ZW1vdmUoJ2Jvb3QtbG9hZGluZycpOwogICAgICB2YXIgcyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlk
KCdza2VsJyk7CiAgICAgIGlmIChzKSBzLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICB9IGNhdGNo
IChlcnIpIHt9CiAgfSwgMzAwMCk7Cn0pKCk7Cjwvc2NyaXB0Pgo8c2NyaXB0PgogICAgbGV0IGFsbENs
aXBzID0gW10sIGN1clRhYiA9ICdhbGwnLCBxdWVyeSA9ICcnLCBjdHhDbGlwID0gbnVsbCwgc2VsZWN0
ZWRJZCA9IDAsIHBpbm5lZFVJID0gZmFsc2U7CiAgICBjb25zdCBUQUJfT1JERVIgPSBbJ2FsbCcsICd0
ZXh0JywgJ2ltYWdlJywgJ2ZpbGUnLCAncGlubmVkJ107CiAgICBjb25zdCB2aWV3TWVtID0gbmV3IE1h
cCgpOwogICAgZnVuY3Rpb24gdmlld01lbUtleSh0YWIsIHEsIHRvZGF5KSB7CiAgICAgICAgcmV0dXJu
IFN0cmluZyh0YWIgfHwgJ2FsbCcpICsgJ1x0JyArIFN0cmluZyhxIHx8ICcnKSArICdcdCcgKyAodG9k
YXkgPyAnMScgOiAnMCcpOwogICAgfQogICAgbGV0IHRhYlN3aXRjaEFuaW1EaXIgPSAwOwogICAgbGV0
IG11bHRpSWRzID0gW107CiAgICBsZXQgdG9kYXlPbmx5ID0gZmFsc2U7CiAgICBsZXQgZGlza1RvdGFs
ID0gMDsKICAgIGxldCBsb2FkaW5nTW9yZSA9IGZhbHNlOwogICAgLy8gRG9uJ3Qgc2hvdyBza2VsZXRv
biBpbW1lZGlhdGVseSDigJRvbmx5IGFmdGVyIFNLRUxfREVMQVlfTVMgaWYgZGF0YSBzdGlsbCBtaXNz
aW5nCiAgICBsZXQgYm9vdExvYWRpbmcgPSBmYWxzZTsKICAgIGxldCB3YWl0aW5nRGF0YSA9IGZhbHNl
OwogICAgbGV0IGhvc3RQdXNoZWRPbmNlID0gZmFsc2U7IC8vIG9ubHkgdGhlbiBtYXkgc2hvd+OAjOaa
guaXoOiusOW9leOAjQogICAgbGV0IHNhd05vbkVtcHR5ID0gZmFsc2U7ICAgIC8vIGlnbm9yZSBib290
c3RyYXAgZW1wdHkgcHVzaGVzIGJlZm9yZSBmaXJzdCByZWFsIGxpc3QKICAgIGxldCBwaW5uZWRUb3Rh
bCA9IDA7ICAgICAgICAvLyBhdXRob3JpdGF0aXZlIOaUtuiXjyBjb3VudCBmcm9tIEFISwogICAgY29u
c3QgU0tFTF9ERUxBWV9NUyA9IDYwOwogICAgd2luZG93Ll9fZGF0YVJlYWR5ID0gZmFsc2U7CiAgICB3
aW5kb3cuX191aUJvb3RlZCA9IHRydWU7CiAgICAvLyBPcGVuIHBhbmVsIHdpdGhvdXQgcGFzdGluZyDi
hpIgYWx3YXlzIGxhbmQgb24gZmlyc3QgaXRlbSAoYWZ0ZXIgZGF0YSBhcnJpdmVzKQogICAgbGV0IHNl
bGVjdEZpcnN0T25TaG93ID0gZmFsc2U7CiAgICBsZXQgbGFzdFBhc3RlSWQgPSAwOwogICAgbGV0IGxh
c3RQYXN0ZVRhYiA9ICdhbGwnOwogICAgbGV0IGxvY2F0ZUFjdGl2ZSA9IGZhbHNlOwogICAgdHJ5IHsg
bGFzdFBhc3RlSWQgPSArbG9jYWxTdG9yYWdlLmdldEl0ZW0oJ2NsaXBMYXN0UGFzdGVJZCcpIHx8IDA7
IH0gY2F0Y2gge30KICAgIHRyeSB7CiAgICAgICAgY29uc3QgdCA9IGxvY2FsU3RvcmFnZS5nZXRJdGVt
KCdjbGlwTGFzdFBhc3RlVGFiJykgfHwgJ2FsbCc7CiAgICAgICAgbGFzdFBhc3RlVGFiID0gWydhbGwn
LCd0ZXh0JywnaW1hZ2UnLCdmaWxlJywncGlubmVkJ10uaW5jbHVkZXModCkgPyB0IDogJ2FsbCc7CiAg
ICB9IGNhdGNoIHt9CiAgICAvLyBQcmVmZXIgc2FtZS1vcmlnaW4gdW5kZXIgY2xpcHVpLmxvY2FsIChB
UFBfSE9TVCDihpIgQ0xJUF9WMV9ESVIvY2xpcHNfc3RvcmUpLgogICAgLy8gY2xpcHMuc3RvcmUgaXMg
YSBkZWRpY2F0ZWQgbWFwcGluZyBmYWxsYmFjayB3aGVuIHNhbWUtb3JpZ2luIGZhaWxzLgogICAgY29u
c3QgU1RPUkVfQkFTRSA9IChsb2NhdGlvbi5vcmlnaW4gJiYgbG9jYXRpb24ub3JpZ2luLmluZGV4T2Yo
J2h0dHBzOi8vJykgPT09IDApCiAgICAgICAgPyAobG9jYXRpb24ub3JpZ2luLnJlcGxhY2UoL1wvJC8s
ICcnKSArICcvY2xpcHNfc3RvcmUvJykKICAgICAgICA6ICdodHRwczovL2NsaXB1aS5sb2NhbC9jbGlw
c19zdG9yZS8nOwogICAgY29uc3QgU1RPUkVfQkFTRV9GQUxMQkFDSyA9ICdodHRwczovL2NsaXBzLnN0
b3JlLyc7CiAgICBmdW5jdGlvbiBtZXRhQ2VudGVySHRtbChleHBhbmRJbm5lcikgewogICAgICAgIGlm
IChleHBhbmRJbm5lciA9PSBudWxsIHx8IGV4cGFuZElubmVyID09PSBmYWxzZSkKICAgICAgICAgICAg
cmV0dXJuIGA8c3BhbiBjbGFzcz0iaS1tZXRhLWNlbnRlciI+PC9zcGFuPmA7CiAgICAgICAgcmV0dXJu
IGA8c3BhbiBjbGFzcz0iaS1tZXRhLWNlbnRlciI+PGJ1dHRvbiBjbGFzcz0iaS1leHBhbmQtYnRuJHtl
eHBhbmRJbm5lci5vbiA/ICcgb24nIDogJyd9IiB0eXBlPSJidXR0b24iIHRpdGxlPSLlsZXlvIAv5pS2
6LW3Ij4ke2V4cGFuZElubmVyLmh0bWx9PC9idXR0b24+PC9zcGFuPmA7CiAgICB9CgogICAgZnVuY3Rp
b24gcmVtZW1iZXJMYXN0UGFzdGUoaWQpIHsKICAgICAgICBsYXN0UGFzdGVJZCA9ICtpZCB8fCAwOwog
ICAgICAgIGxhc3RQYXN0ZVRhYiA9IGN1clRhYiB8fCAnYWxsJzsKICAgICAgICB0cnkgewogICAgICAg
ICAgICBsb2NhbFN0b3JhZ2Uuc2V0SXRlbSgnY2xpcExhc3RQYXN0ZUlkJywgU3RyaW5nKGxhc3RQYXN0
ZUlkKSk7CiAgICAgICAgICAgIGxvY2FsU3RvcmFnZS5zZXRJdGVtKCdjbGlwTGFzdFBhc3RlVGFiJywg
bGFzdFBhc3RlVGFiKTsKICAgICAgICB9IGNhdGNoIHt9CiAgICAgICAgdXBkYXRlTG9jYXRlQnRuKCk7
CiAgICB9CiAgICBmdW5jdGlvbiB1cGRhdGVMb2NhdGVCdG4oKSB7CiAgICAgICAgY29uc3QgYnRuID0g
ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi1sb2NhdGUnKTsKICAgICAgICBpZiAoIWJ0bikgcmV0
dXJuOwogICAgICAgIGJ0bi5kaXNhYmxlZCA9ICFsYXN0UGFzdGVJZDsKICAgICAgICBidG4uY2xhc3NM
aXN0LnRvZ2dsZSgnaGFzLXRhcmdldCcsICEhbGFzdFBhc3RlSWQpOwogICAgICAgIGJ0bi5jbGFzc0xp
c3QudG9nZ2xlKCdvbicsIGxvY2F0ZUFjdGl2ZSAmJiAhIWxhc3RQYXN0ZUlkKTsKICAgICAgICBidG4u
dGl0bGUgPSAhbGFzdFBhc3RlSWQKICAgICAgICAgICAgPyAn5pqC5peg5LiK5qyh5L2/55So5L2N572u
JwogICAgICAgICAgICA6IChsb2NhdGVBY3RpdmUgPyAn5Y+W5raI5a6a5L2N77yM5Zue5Yiw56ys5LiA
5p2hJyA6ICflrprkvY3liLDkuIrmrKHkvb/nlKjnmoTmnaHnm64nKTsKICAgIH0KICAgIGZ1bmN0aW9u
IHNlbGVjdEZpcnN0SXRlbSgpIHsKICAgICAgICBsb2NhdGVBY3RpdmUgPSBmYWxzZTsKICAgICAgICB3
aW5kb3cuX19wZW5kaW5nSnVtcElkID0gMDsKICAgICAgICB3aW5kb3cuX19qdW1wTG9hZFRyaWVzID0g
MDsKICAgICAgICBzZWxlY3RGaXJzdE9uU2hvdyA9IGZhbHNlOwogICAgICAgIGNvbnN0IHZpcyA9IHZp
c2libGVMaXN0KCk7CiAgICAgICAgaWYgKCF2aXMubGVuZ3RoKSB7CiAgICAgICAgICAgIHNlbGVjdGVk
SWQgPSAwOwogICAgICAgICAgICBzeW5jSXRlbUhpZ2hsaWdodCgpOwogICAgICAgICAgICB1cGRhdGVM
b2NhdGVCdG4oKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBzZWxlY3RlZElk
ID0gdmlzWzBdLmlkOwogICAgICAgIHJhbmdlQW5jaG9ySWQgPSBzZWxlY3RlZElkOwogICAgICAgIHJh
bmdlQW5jaG9yQ2xpY2tlZCA9IGZhbHNlOwogICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSAwOwogICAg
ICAgIHN5bmNJdGVtSGlnaGxpZ2h0KCk7CiAgICAgICAgY29uc3QgZWwgPSBsaXN0RWwucXVlcnlTZWxl
Y3RvcignLml0bVtkYXRhLWlkPSInICsgc2VsZWN0ZWRJZCArICciXScpOwogICAgICAgIGlmIChlbCkg
ZWwuc2Nyb2xsSW50b1ZpZXcoeyBibG9jazogJ25lYXJlc3QnIH0pOwogICAgICAgIHVwZGF0ZUxvY2F0
ZUJ0bigpOwogICAgfQogICAgZnVuY3Rpb24ganVtcFRvTGFzdFBhc3RlKCkgewogICAgICAgIGlmICgh
bGFzdFBhc3RlSWQpIHJldHVybjsKICAgICAgICAvLyBBbHJlYWR5IGxvY2F0ZWQgb24gbGFzdCBwYXN0
ZSDihpIgY2FuY2VsIGFuZCBzZWxlY3QgZmlyc3QKICAgICAgICBpZiAobG9jYXRlQWN0aXZlICYmICtz
ZWxlY3RlZElkID09PSArbGFzdFBhc3RlSWQpIHsKICAgICAgICAgICAgc2VsZWN0Rmlyc3RJdGVtKCk7
CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgbG9jYXRlQWN0aXZlID0gdHJ1ZTsK
ICAgICAgICBzZWxlY3RGaXJzdE9uU2hvdyA9IGZhbHNlOwogICAgICAgIC8vIENsZWFyIGZpbHRlcnMg
c28gdGhlIGl0ZW0gaXMgZmluZGFibGUgb24gdGhlIHRhYiB3aGVyZSBpdCB3YXMgdXNlZAogICAgICAg
IHF1ZXJ5ID0gJyc7CiAgICAgICAgdG9kYXlPbmx5ID0gZmFsc2U7CiAgICAgICAgdHJ5IHsKICAgICAg
ICAgICAgY29uc3Qgc3JjaCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gnKTsKICAgICAg
ICAgICAgY29uc3Qgc2NsciA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gtY2xyJyk7CiAg
ICAgICAgICAgIGNvbnN0IHdyYXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLXdyYXAn
KTsKICAgICAgICAgICAgY29uc3QgYnRuVG9kYXkgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRu
LXRvZGF5Jyk7CiAgICAgICAgICAgIGlmIChzcmNoKSB7IHNyY2gudmFsdWUgPSAnJzsgc3JjaC5jbGFz
c0xpc3QucmVtb3ZlKCdoYXMtdmFsJyk7IH0KICAgICAgICAgICAgaWYgKHNjbHIpIHNjbHIuc3R5bGUu
ZGlzcGxheSA9ICdub25lJzsKICAgICAgICAgICAgaWYgKHdyYXApIHdyYXAuY2xhc3NMaXN0LnJlbW92
ZSgnb3BlbicpOwogICAgICAgICAgICBpZiAoYnRuVG9kYXkpIGJ0blRvZGF5LmNsYXNzTGlzdC5yZW1v
dmUoJ29uJyk7CiAgICAgICAgfSBjYXRjaCB7fQogICAgICAgIGNvbnN0IHRhYiA9IFsnYWxsJywndGV4
dCcsJ2ltYWdlJywnZmlsZScsJ3Bpbm5lZCddLmluY2x1ZGVzKGxhc3RQYXN0ZVRhYikKICAgICAgICAg
ICAgPyBsYXN0UGFzdGVUYWIgOiAnYWxsJzsKICAgICAgICBjb25zdCBwcmV2VGFiID0gY3VyVGFiOwog
ICAgICAgIGN1clRhYiA9IHRhYjsKICAgICAgICBsb2FkaW5nTW9yZSA9IGZhbHNlOwogICAgICAgIG1h
cmtUYWIodGFiKTsKICAgICAgICBjbGVhck11bHRpKCk7CiAgICAgICAgc2VsZWN0ZWRJZCA9IGxhc3RQ
YXN0ZUlkOwogICAgICAgIHdpbmRvdy5fX3BlbmRpbmdKdW1wSWQgPSBsYXN0UGFzdGVJZDsKICAgICAg
ICB3aW5kb3cuX19qdW1wTG9hZFRyaWVzID0gMDsKICAgICAgICB3aW5kb3cuX19qdW1wRmVsbEJhY2sg
PSBmYWxzZTsKICAgICAgICB1cGRhdGVMb2NhdGVCdG4oKTsKICAgICAgICByZXF1ZXN0VmlldygpOwog
ICAgfQoKICAgIGZ1bmN0aW9uIHJlcXVlc3RWaWV3KCkgewogICAgICAgIGNvbnN0IHRhYiA9IGN1clRh
YiwgcSA9IHF1ZXJ5LCB0b2RheSA9IHRvZGF5T25seSA/ICcxJyA6ICcwJzsKICAgICAgICBpZiAod2lu
ZG93Ll9fdmlld1JhZikgY2FuY2VsQW5pbWF0aW9uRnJhbWUod2luZG93Ll9fdmlld1JhZik7CiAgICAg
ICAgd2luZG93Ll9fdmlld1JhZiA9IHJlcXVlc3RBbmltYXRpb25GcmFtZSgoKSA9PiB7CiAgICAgICAg
ICAgIHdpbmRvdy5fX3ZpZXdSYWYgPSAwOwogICAgICAgICAgICBzZXRUaW1lb3V0KCgpID0+IGFoaygn
c2V0VmlldycsIHRhYiwgcSwgdG9kYXkpLCAwKTsKICAgICAgICB9KTsKICAgIH0KICAgIC8qKiBEZWJv
dW5jZWQgQUhLIHN5bmMgYWZ0ZXIgdmlld01lbSBpbnN0YW50IHBhaW50IOKAlGF2b2lkcyB0YWItc3dp
dGNoIGRvdWJsZSBQdXNoQ2xpcHMgKi8KICAgIGZ1bmN0aW9uIHNvZnRSZXF1ZXN0VmlldygpIHsKICAg
ICAgICBpZiAod2luZG93Ll9fc29mdFZpZXdUKSBjbGVhclRpbWVvdXQod2luZG93Ll9fc29mdFZpZXdU
KTsKICAgICAgICB3aW5kb3cuX19zb2Z0Vmlld1QgPSBzZXRUaW1lb3V0KCgpID0+IHsKICAgICAgICAg
ICAgd2luZG93Ll9fc29mdFZpZXdUID0gMDsKICAgICAgICAgICAgcmVxdWVzdFZpZXcoKTsKICAgICAg
ICB9LCAzMjApOwogICAgfQogICAgZnVuY3Rpb24gcmVxdWVzdE1vcmUoKSB7CiAgICAgICAgaWYgKGxv
YWRpbmdNb3JlKSByZXR1cm47CiAgICAgICAgaWYgKGRpc2tUb3RhbCA+IDAgJiYgYWxsQ2xpcHMubGVu
Z3RoID49IGRpc2tUb3RhbCkgcmV0dXJuOwogICAgICAgIGxvYWRpbmdNb3JlID0gdHJ1ZTsKICAgICAg
ICBzZXRUaW1lb3V0KCgpID0+IGFoaygnbG9hZE1vcmUnKSwgMCk7CiAgICB9CiAgICBjb25zdCBFTVBU
WV9NU0cgPSB7CiAgICAgICAgYWxsOiAgICAn5pqC5peg6K6w5b2V77yM5aSN5Yi25ZCO6Ieq5Yqo5Ye6
546wJywKICAgICAgICB0ZXh0OiAgICfmmoLml6DmlofmnKwnLAogICAgICAgIGltYWdlOiAgJ+aaguaX
oOWbvuWDjycsCiAgICAgICAgZmlsZTogICAn5pqC5peg5paH5Lu2JywKICAgICAgICBwaW5uZWQ6ICfm
moLml6DmlLbol48nCiAgICB9OwoKICAgIGZ1bmN0aW9uIGFoa0ludm9rZShtZXRob2QsIGFyZ3MpIHsK
ICAgICAgICB0cnkgewogICAgICAgICAgICBjb25zdCBob3N0ID0gY2hyb21lLndlYnZpZXcuaG9zdE9i
amVjdHMuc3luYy5haGs7CiAgICAgICAgICAgIGlmICghaG9zdCkgcmV0dXJuOwogICAgICAgICAgICBs
ZXQgY2FsbGVkID0gZmFsc2U7CiAgICAgICAgICAgIGlmICh0eXBlb2YgaG9zdC5jYWxsID09PSAnZnVu
Y3Rpb24nKSB7CiAgICAgICAgICAgICAgICB0cnkgeyBob3N0LmNhbGwobWV0aG9kLCAuLi5hcmdzKTsg
Y2FsbGVkID0gdHJ1ZTsgfSBjYXRjaCB7fQogICAgICAgICAgICB9CiAgICAgICAgICAgIGlmICghY2Fs
bGVkICYmIHR5cGVvZiBob3N0W21ldGhvZF0gPT09ICdmdW5jdGlvbicpIHsKICAgICAgICAgICAgICAg
IHRyeSB7IGhvc3RbbWV0aG9kXSguLi5hcmdzKTsgY2FsbGVkID0gdHJ1ZTsgfSBjYXRjaCB7fQogICAg
ICAgICAgICAgICAgaWYgKCFjYWxsZWQpIHsKICAgICAgICAgICAgICAgICAgICB0cnkgeyBob3N0W21l
dGhvZF0oLi4uYXJncyk7IGNhbGxlZCA9IHRydWU7IH0gY2F0Y2gge30KICAgICAgICAgICAgICAgIH0K
ICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAoIWNhbGxlZCAmJiBob3N0W21ldGhvZF0gIT0gbnVs
bCAmJiB0eXBlb2YgaG9zdFttZXRob2RdICE9PSAnZnVuY3Rpb24nKSB7CiAgICAgICAgICAgICAgICB0
cnkgeyB2b2lkIGhvc3RbbWV0aG9kXTsgfSBjYXRjaCB7fQogICAgICAgICAgICB9CiAgICAgICAgfSBj
YXRjaCAoZSkgeyBjb25zb2xlLndhcm4oJ2Foay4nICsgbWV0aG9kLCBlKTsgfQogICAgfQogICAgZnVu
Y3Rpb24gYWhrKG1ldGhvZCwgLi4uYXJncykgewogICAgICAgIGFoa0ludm9rZShtZXRob2QsIGFyZ3Mp
OwogICAgfQogICAgZnVuY3Rpb24gYWhrUmV0KG1ldGhvZCwgLi4uYXJncykgewogICAgICAgIHRyeSB7
CiAgICAgICAgICAgIGNvbnN0IGhvc3QgPSBjaHJvbWUud2Vidmlldy5ob3N0T2JqZWN0cy5zeW5jLmFo
azsKICAgICAgICAgICAgaWYgKCFob3N0KSByZXR1cm4gbnVsbDsKICAgICAgICAgICAgbGV0IHJldCA9
IG51bGw7CiAgICAgICAgICAgIGlmICh0eXBlb2YgaG9zdC5jYWxsID09PSAnZnVuY3Rpb24nKSB7CiAg
ICAgICAgICAgICAgICB0cnkgeyByZXQgPSBob3N0LmNhbGwobWV0aG9kLCAuLi5hcmdzKTsgfSBjYXRj
aCB7fQogICAgICAgICAgICB9CiAgICAgICAgICAgIGlmIChyZXQgPT0gbnVsbCAmJiB0eXBlb2YgaG9z
dFttZXRob2RdID09PSAnZnVuY3Rpb24nKSB7CiAgICAgICAgICAgICAgICB0cnkgeyByZXQgPSBob3N0
W21ldGhvZF0oLi4uYXJncyk7IH0gY2F0Y2gge30KICAgICAgICAgICAgICAgIGlmIChyZXQgPT0gbnVs
bCkgewogICAgICAgICAgICAgICAgICAgIHRyeSB7IHJldCA9IGhvc3RbbWV0aG9kXSguLi5hcmdzKTsg
fSBjYXRjaCB7fQogICAgICAgICAgICAgICAgfQogICAgICAgICAgICB9CiAgICAgICAgICAgIGlmIChy
ZXQgPT0gbnVsbCAmJiBob3N0W21ldGhvZF0gIT0gbnVsbCAmJiB0eXBlb2YgaG9zdFttZXRob2RdICE9
PSAnZnVuY3Rpb24nKQogICAgICAgICAgICAgICAgcmV0ID0gaG9zdFttZXRob2RdOwogICAgICAgICAg
ICBpZiAocmV0ID09IG51bGwpIHJldHVybiBudWxsOwogICAgICAgICAgICBpZiAodHlwZW9mIHJldCA9
PT0gJ3N0cmluZycgfHwgdHlwZW9mIHJldCA9PT0gJ251bWJlcicgfHwgdHlwZW9mIHJldCA9PT0gJ2Jv
b2xlYW4nKQogICAgICAgICAgICAgICAgcmV0dXJuIHJldDsKICAgICAgICAgICAgdHJ5IHsgcmV0dXJu
IFN0cmluZyhyZXQpOyB9IGNhdGNoIHsgcmV0dXJuIHJldDsgfQogICAgICAgIH0gY2F0Y2ggKGUpIHsg
Y29uc29sZS53YXJuKCdhaGtSZXQuJyArIG1ldGhvZCwgZSk7IH0KICAgICAgICByZXR1cm4gbnVsbDsK
ICAgIH0KCiAgICAvLyBFYXJseSBBSEsgX19zZXRUaHVtYiBjYW4gYXJyaXZlIGJlZm9yZSBET00gbm9k
ZXMgZXhpc3Qg4oCUIGtlZXAgdW50aWwgYmluZAogICAgY29uc3QgdGh1bWJDYWNoZSA9IG5ldyBNYXAo
KTsKCiAgICAvKiogUHJlZmVyIGNhY2hlIC8gZGF0YS1VUkwsIHRoZW4gdGhfKi5qcGcgdmlhIHZpcnR1
YWwgaG9zdCwgdGhlbiBvcmlnaW5hbCAqLwogICAgZnVuY3Rpb24gYmluZFN0b3JlVGh1bWIoaW1nLCBm
aWxlLCBpZCwgZmFsbGJhY2spIHsKICAgICAgICBpbWcuZGF0YXNldC50aHVtYklkID0gU3RyaW5nKGlk
KTsKICAgICAgICBpbWcuYWx0ID0gJyc7CiAgICAgICAgaW1nLmNsYXNzTGlzdC5hZGQoJ3RodW1iLWxv
YWRpbmcnKTsKICAgICAgICBjb25zdCB3cmFwID0gaW1nLnBhcmVudEVsZW1lbnQ7CiAgICAgICAgaWYg
KHdyYXAgJiYgd3JhcC5jbGFzc0xpc3QuY29udGFpbnMoJ2ktdGh1bWItd3JhcCcpKQogICAgICAgICAg
ICB3cmFwLmNsYXNzTGlzdC5hZGQoJ3dhaXRpbmcnKTsKICAgICAgICBjb25zdCBjbGVhcldhaXQgPSAo
KSA9PiB7CiAgICAgICAgICAgIGltZy5jbGFzc0xpc3QucmVtb3ZlKCd0aHVtYi1sb2FkaW5nJyk7CiAg
ICAgICAgICAgIGlmICh3cmFwKSB3cmFwLmNsYXNzTGlzdC5yZW1vdmUoJ3dhaXRpbmcnKTsKICAgICAg
ICAgICAgaWYgKGltZy5fZmFpbFRpbWVyKSB0cnkgeyBjbGVhclRpbWVvdXQoaW1nLl9mYWlsVGltZXIp
OyB9IGNhdGNoIHt9CiAgICAgICAgfTsKICAgICAgICBjb25zdCBmYWlsVGltZXIgPSBzZXRUaW1lb3V0
KCgpID0+IHsKICAgICAgICAgICAgaWYgKCFpbWcuc3JjIHx8IGltZy5uYXR1cmFsV2lkdGggPCAxKQog
ICAgICAgICAgICAgICAgaW1nLmFsdCA9ICfml6Dms5XliqDovb0nOwogICAgICAgICAgICBjbGVhcldh
aXQoKTsKICAgICAgICB9LCAxMjAwMCk7CiAgICAgICAgaW1nLl9mYWlsVGltZXIgPSBmYWlsVGltZXI7
CiAgICAgICAgY29uc3QgcHJldkxvYWQgPSBpbWcub25sb2FkOwogICAgICAgIGltZy5vbmxvYWQgPSBl
ID0+IHsKICAgICAgICAgICAgY2xlYXJXYWl0KCk7CiAgICAgICAgICAgIGltZy5hbHQgPSAnJzsKICAg
ICAgICAgICAgaWYgKHR5cGVvZiBwcmV2TG9hZCA9PT0gJ2Z1bmN0aW9uJykgcHJldkxvYWQuY2FsbChp
bWcsIGUpOwogICAgICAgIH07CiAgICAgICAgY29uc3QgYmFyZSA9IGZpbGUgPyBTdHJpbmcoZmlsZSku
c3BsaXQoL1tcXC9dLykucG9wKCkgOiAnJzsKICAgICAgICBjb25zdCB0aE5hbWUgPSBiYXJlID8gKCd0
aF8nICsgYmFyZS5yZXBsYWNlKC9cLlteLl0rJC8sICcnKSArICcuanBnJykgOiAnJzsKICAgICAgICBp
bWcub25lcnJvciA9ICgpID0+IHsKICAgICAgICAgICAgY29uc3Qgc3RlcCA9IE51bWJlcihpbWcuZGF0
YXNldC5zdGVwIHx8IDApOwogICAgICAgICAgICBpZiAoc3RlcCA8IDIgJiYgYmFyZSkgewogICAgICAg
ICAgICAgICAgaW1nLmRhdGFzZXQuc3RlcCA9ICcyJzsKICAgICAgICAgICAgICAgIGltZy5zcmMgPSBT
VE9SRV9CQVNFICsgZW5jb2RlVVJJQ29tcG9uZW50KGJhcmUpOwogICAgICAgICAgICAgICAgcmV0dXJu
OwogICAgICAgICAgICB9CiAgICAgICAgICAgIGlmIChzdGVwIDwgMyAmJiAodGhOYW1lIHx8IGJhcmUp
KSB7CiAgICAgICAgICAgICAgICBpbWcuZGF0YXNldC5zdGVwID0gJzMnOwogICAgICAgICAgICAgICAg
aW1nLnNyYyA9IFNUT1JFX0JBU0VfRkFMTEJBQ0sgKyBlbmNvZGVVUklDb21wb25lbnQodGhOYW1lIHx8
IGJhcmUpOwogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICB9CiAgICAgICAgICAgIGlm
IChzdGVwIDwgNCAmJiBiYXJlICYmIHRoTmFtZSkgewogICAgICAgICAgICAgICAgaW1nLmRhdGFzZXQu
c3RlcCA9ICc0JzsKICAgICAgICAgICAgICAgIGltZy5zcmMgPSBTVE9SRV9CQVNFX0ZBTExCQUNLICsg
ZW5jb2RlVVJJQ29tcG9uZW50KGJhcmUpOwogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAg
ICB9CiAgICAgICAgICAgIC8vIEtlZXAgc2hpbW1lcjsgQUhLIF9fc2V0VGh1bWIgd2lsbCBmaWxsIGlu
CiAgICAgICAgICAgIGltZy5yZW1vdmVBdHRyaWJ1dGUoJ3NyYycpOwogICAgICAgICAgICBpbWcuY2xh
c3NMaXN0LmFkZCgndGh1bWItbG9hZGluZycpOwogICAgICAgICAgICBpZiAod3JhcCkgd3JhcC5jbGFz
c0xpc3QuYWRkKCd3YWl0aW5nJyk7CiAgICAgICAgfTsKICAgICAgICBjb25zdCBjYWNoZWQgPSB0aHVt
YkNhY2hlLmdldChTdHJpbmcoaWQpKTsKICAgICAgICAvLyBBY2NlcHQgZGF0YS1VUkwgb3IgaG9zdCBV
UkwgZnJvbSBwcmlvciBfX3NldFRodW1iIChyZS1yZW5kZXIgbXVzdCBub3QgZHJvcCBpdCkKICAgICAg
ICBpZiAoY2FjaGVkICYmIFN0cmluZyhjYWNoZWQpLmxlbmd0aCkgewogICAgICAgICAgICBpbWcuZGF0
YXNldC5zdGVwID0gJzknOwogICAgICAgICAgICBpbWcuc3JjID0gU3RyaW5nKGNhY2hlZCk7CiAgICAg
ICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgY29uc3QgZGF0YVVybCA9IChmYWxsYmFjayAm
JiBTdHJpbmcoZmFsbGJhY2spLnN0YXJ0c1dpdGgoJ2RhdGE6JykpCiAgICAgICAgICAgID8gU3RyaW5n
KGZhbGxiYWNrKSA6ICcnOwogICAgICAgIGlmIChkYXRhVXJsKSB7CiAgICAgICAgICAgIGltZy5kYXRh
c2V0LnN0ZXAgPSAnOSc7CiAgICAgICAgICAgIGltZy5zcmMgPSBkYXRhVXJsOwogICAgICAgICAgICBy
ZXR1cm47CiAgICAgICAgfQogICAgICAgIGlmIChiYXJlKSB7CiAgICAgICAgICAgIC8vIFByZWZlciBs
aXN0IHRodW1iIEpQRUcgKHNtYWxsKSBvbiBkZWRpY2F0ZWQgc3RvcmUgaG9zdAogICAgICAgICAgICBp
bWcuZGF0YXNldC5zdGVwID0gJzEnOwogICAgICAgICAgICBpbWcuc3JjID0gU1RPUkVfQkFTRSArIGVu
Y29kZVVSSUNvbXBvbmVudCh0aE5hbWUgfHwgYmFyZSk7CiAgICAgICAgfSBlbHNlIHsKICAgICAgICAg
ICAgLy8gTm8gZmlsZSB5ZXQgKGp1c3QgY29waWVkKSDigJRrZWVwIHNoaW1tZXI7IEluamVjdExpdmVJ
bWFnZVRodW1iIC8gX19zZXRUaHVtYiBmaWxscyBpbgogICAgICAgICAgICBpbWcuY2xhc3NMaXN0LmFk
ZCgndGh1bWItbG9hZGluZycpOwogICAgICAgICAgICBpZiAod3JhcCkgd3JhcC5jbGFzc0xpc3QuYWRk
KCd3YWl0aW5nJyk7CiAgICAgICAgfQogICAgfQoKICAgIHdpbmRvdy5fX3NldFRodW1iID0gKGlkLCB1
cmwpID0+IHsKICAgICAgICBpZiAoIXVybCkgcmV0dXJuOwogICAgICAgIGNvbnN0IGtleSA9IFN0cmlu
ZyhpZCk7CiAgICAgICAgdGh1bWJDYWNoZS5zZXQoa2V5LCB1cmwpOwogICAgICAgIGNvbnN0IGFwcGx5
ID0gaW1nID0+IHsKICAgICAgICAgICAgaWYgKGltZy5fZmFpbFRpbWVyKSB0cnkgeyBjbGVhclRpbWVv
dXQoaW1nLl9mYWlsVGltZXIpOyB9IGNhdGNoIHt9CiAgICAgICAgICAgIGltZy5vbmVycm9yID0gbnVs
bDsKICAgICAgICAgICAgaW1nLmFsdCA9ICcnOwogICAgICAgICAgICBpbWcuY2xhc3NMaXN0LnJlbW92
ZSgndGh1bWItbG9hZGluZycpOwogICAgICAgICAgICBjb25zdCB3cmFwID0gaW1nLnBhcmVudEVsZW1l
bnQ7CiAgICAgICAgICAgIGlmICh3cmFwKSB3cmFwLmNsYXNzTGlzdC5yZW1vdmUoJ3dhaXRpbmcnKTsK
ICAgICAgICAgICAgaW1nLnNyYyA9IHVybDsKICAgICAgICB9OwogICAgICAgIGxldCBoaXQgPSAwOwog
ICAgICAgIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5pdG1bZGF0YS1pZD0iJyArIGtleSArICci
XSBpbWcuaS10aHVtYicpLmZvckVhY2goaW1nID0+IHsKICAgICAgICAgICAgYXBwbHkoaW1nKTsgaGl0
Kys7CiAgICAgICAgfSk7CiAgICAgICAgaWYgKCFoaXQpIHsKICAgICAgICAgICAgZG9jdW1lbnQucXVl
cnlTZWxlY3RvckFsbCgnaW1nLmktdGh1bWJbZGF0YS10aHVtYi1pZD0iJyArIGtleSArICciXScpLmZv
ckVhY2goYXBwbHkpOwogICAgICAgIH0KICAgIH07CgogICAgZnVuY3Rpb24gaXNEcmFnRXhjbHVkZSh0
KSB7CiAgICAgICAgcmV0dXJuICEhdC5jbG9zZXN0KCcjc2VhcmNoLXdyYXAsICNidG4tc2VhcmNoLCAj
YnRuLWxvY2F0ZSwgI2J0bi10b2RheSwgI2J0bi1waW4sICNidG4tY2xyLCAjbXVsdGktY250LCAudGFi
LCAuaXRtLCAjdGFiLWFjdGlvbnMsICNjdHgsICNjbHItZGxnLCAjcGF0aC10aXAsIGJ1dHRvbiwgaW5w
dXQsIGEnKTsKICAgIH0KICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdhcHAnKS5hZGRFdmVudExp
c3RlbmVyKCdtb3VzZWRvd24nLCBlID0+IHsKICAgICAgICBpZiAoZS5idXR0b24gIT09IDApIHJldHVy
bjsKICAgICAgICBpZiAoaXNEcmFnRXhjbHVkZShlLnRhcmdldCkpIHJldHVybjsKICAgICAgICBlLnBy
ZXZlbnREZWZhdWx0KCk7CiAgICAgICAgYWhrKCdzdGFydERyYWcnKTsKICAgIH0sIHRydWUpOwoKICAg
IGNvbnN0IGlzVXJsICA9IHMgPT4gL15odHRwcz86XC9cLy9pLnRlc3QoKHMgfHwgJycpLnRyaW0oKSk7
CgogICAgZnVuY3Rpb24gYWdvKGRhdGVTdHIpIHsKICAgICAgICB0cnkgewogICAgICAgICAgICBjb25z
dCBkID0gbmV3IERhdGUoU3RyaW5nKGRhdGVTdHIpLnJlcGxhY2UoJyAnLCAnVCcpKTsKICAgICAgICAg
ICAgY29uc3QgcyA9IChEYXRlLm5vdygpIC0gZCkgLyAxMDAwIHwgMDsKICAgICAgICAgICAgaWYgKHMg
PCA2MCkgcmV0dXJuICfliJrliJonOwogICAgICAgICAgICBpZiAocyA8IDM2MDApIHJldHVybiAocyAv
IDYwIHwgMCkgKyAnIOWIhumSn+WJjSc7CiAgICAgICAgICAgIGlmIChzIDwgODY0MDApIHJldHVybiAo
cyAvIDM2MDAgfCAwKSArICcg5bCP5pe25YmNJzsKICAgICAgICAgICAgcmV0dXJuIChzIC8gODY0MDAg
fCAwKSArICcg5aSp5YmNJzsKICAgICAgICB9IGNhdGNoIHsgcmV0dXJuIGRhdGVTdHI7IH0KICAgIH0K
CiAgICBmdW5jdGlvbiBub3JtVHlwZSh0KSB7CiAgICAgICAgdCA9IFN0cmluZyh0IHx8ICcnKS50b0xv
d2VyQ2FzZSgpOwogICAgICAgIGlmICh0ID09PSAnaW1hZ2UnIHx8IHQgPT09ICdpbWcnIHx8IHQgPT09
ICdiaXRtYXAnKSByZXR1cm4gJ2ltYWdlJzsKICAgICAgICBpZiAodCA9PT0gJ2ZpbGUnICB8fCB0ID09
PSAnZmlsZXMnKSByZXR1cm4gJ2ZpbGUnOwogICAgICAgIHJldHVybiAndGV4dCc7CiAgICB9CiAgICBm
dW5jdGlvbiBpc1Bpbm5lZChjKSB7CiAgICAgICAgcmV0dXJuIGMucGlubmVkID09PSB0cnVlIHx8IGMu
cGlubmVkID09PSAxIHx8IGMucGlubmVkID09PSAndHJ1ZScgfHwgYy5waW5uZWQgPT09ICcxJzsKICAg
IH0KICAgIGZ1bmN0aW9uIGlzUGFzdGVkKGMpIHsKICAgICAgICByZXR1cm4gYy5wYXN0ZWQgPT09IHRy
dWUgfHwgYy5wYXN0ZWQgPT09IDEgfHwgYy5wYXN0ZWQgPT09ICd0cnVlJyB8fCBjLnBhc3RlZCA9PT0g
JzEnOwogICAgfQoKICAgIGZ1bmN0aW9uIGlzTWFya2Rvd24odGV4dCkgewogICAgICAgIGlmICghdGV4
dCB8fCB0ZXh0Lmxlbmd0aCA8IDQpIHJldHVybiBmYWxzZTsKICAgICAgICByZXR1cm4gLyg/Ol58XG4p
I3sxLDZ9IHxeWy0qK10gfFwqXCpbXipcbl0rXCpcKnxfX1teX1xuXStfX3woPzpefFxuKT4gfGBgYHxg
W15gXG5dK2B8XFtbXlxdXStcXVwoW14pXStcKXxcfC4rXHwuK1x8L20udGVzdCh0ZXh0KTsKICAgIH0K
ICAgIGZ1bmN0aW9uIGNsaXBVc2VzTUljb24oYykgewogICAgICAgIGlmICghYykgcmV0dXJuIGZhbHNl
OwogICAgICAgIGlmIChjLmlzTWQgPT09IHRydWUgfHwgYy5pc01kID09PSAxIHx8IGMuaXNNZCA9PT0g
J3RydWUnIHx8IGMuaXNNZCA9PT0gJzEnKSByZXR1cm4gdHJ1ZTsKICAgICAgICBpZiAoYy5pc1JpY2gg
PT09IHRydWUgfHwgYy5pc1JpY2ggPT09IDEgfHwgYy5pc1JpY2ggPT09ICd0cnVlJyB8fCBjLmlzUmlj
aCA9PT0gJzEnKSByZXR1cm4gdHJ1ZTsKICAgICAgICBjb25zdCB0ID0gU3RyaW5nKGMudHlwZSB8fCAn
JykudG9Mb3dlckNhc2UoKTsKICAgICAgICBpZiAodCAmJiB0ICE9PSAndGV4dCcgJiYgdCAhPT0gJ2xp
bmsnKSByZXR1cm4gZmFsc2U7CiAgICAgICAgcmV0dXJuIGlzTWFya2Rvd24oYy5kYXRhIHx8IGMucHJl
dmlldyB8fCAnJyk7CiAgICB9CiAgICBmdW5jdGlvbiBlc2NBdHRyKHMpIHsKICAgICAgICByZXR1cm4g
U3RyaW5nKHMgfHwgJycpCiAgICAgICAgICAgIC5yZXBsYWNlKC8mL2csICcmYW1wOycpCiAgICAgICAg
ICAgIC5yZXBsYWNlKC8iL2csICcmcXVvdDsnKQogICAgICAgICAgICAucmVwbGFjZSgvPC9nLCAnJmx0
OycpCiAgICAgICAgICAgIC5yZXBsYWNlKC8+L2csICcmZ3Q7Jyk7CiAgICB9CgogICAgZnVuY3Rpb24g
dG9kYXlQcmVmaXgoKSB7CiAgICAgICAgY29uc3QgZCA9IG5ldyBEYXRlKCk7CiAgICAgICAgY29uc3Qg
cCA9IG4gPT4gU3RyaW5nKG4pLnBhZFN0YXJ0KDIsICcwJyk7CiAgICAgICAgcmV0dXJuIGQuZ2V0RnVs
bFllYXIoKSArICctJyArIHAoZC5nZXRNb250aCgpICsgMSkgKyAnLScgKyBwKGQuZ2V0RGF0ZSgpKTsK
ICAgIH0KICAgIGZ1bmN0aW9uIGlzVG9kYXlDbGlwKGMpIHsKICAgICAgICByZXR1cm4gU3RyaW5nKGMu
dGltZSB8fCAnJykuc3RhcnRzV2l0aCh0b2RheVByZWZpeCgpKTsKICAgIH0KCiAgICBmdW5jdGlvbiBj
bGlwSGF5KGMpIHsKICAgICAgICByZXR1cm4gU3RyaW5nKGMucHJldmlldyB8fCAnJykgKyAnICcgKyBT
dHJpbmcoYy5kYXRhIHx8ICcnKSArICcgJwogICAgICAgICAgICArIFN0cmluZyhjLmxpbmtUaXRsZSB8
fCAnJykgKyAnICcgKyBTdHJpbmcoYy5mYXZUaXRsZSB8fCAnJyk7CiAgICB9CiAgICAvKiogTWF0Y2gg
QUhLIEl0ZW1NYXRjaGVzVmlldyBsaXN0IHNlYXJjaCDigJQgcHJldmlldyAoKyBzaG9ydCBib2R5IGZh
bGxiYWNrKSwgbm90IGZ1bGwgZGF0YSAqLwogICAgZnVuY3Rpb24gY2xpcFNlYXJjaEhheShjKSB7CiAg
ICAgICAgY29uc3QgdHlwZSA9IFN0cmluZyhjLnR5cGUgfHwgJycpLnRvTG93ZXJDYXNlKCk7CiAgICAg
ICAgaWYgKHR5cGUgPT09ICdpbWFnZScpCiAgICAgICAgICAgIHJldHVybiBTdHJpbmcoYy5mYXZUaXRs
ZSB8fCAnJyk7CiAgICAgICAgaWYgKHR5cGUgPT09ICdmaWxlJykgewogICAgICAgICAgICByZXR1cm4g
U3RyaW5nKGMucHJldmlldyB8fCAnJykgKyAnICcgKyBTdHJpbmcoYy5kYXRhIHx8ICcnKSArICcgJwog
ICAgICAgICAgICAgICAgKyBTdHJpbmcoYy5mYXZUaXRsZSB8fCAnJyk7CiAgICAgICAgfQogICAgICAg
IGxldCBwcmV2ID0gU3RyaW5nKGMucHJldmlldyB8fCAnJyk7CiAgICAgICAgaWYgKCFwcmV2ICYmIGMu
ZGF0YSkKICAgICAgICAgICAgcHJldiA9IFN0cmluZyhjLmRhdGEpLnNsaWNlKDAsIDUwMCk7CiAgICAg
ICAgcmV0dXJuIHByZXYgKyAnICcgKyBTdHJpbmcoYy5saW5rVGl0bGUgfHwgJycpICsgJyAnICsgU3Ry
aW5nKGMuZmF2VGl0bGUgfHwgJycpOwogICAgfQogICAgZnVuY3Rpb24gY2xpcE1hdGNoZXNTZWFyY2go
YywgdGVybUwpIHsKICAgICAgICBjb25zdCB0eXBlID0gU3RyaW5nKGMudHlwZSB8fCAnJykudG9Mb3dl
ckNhc2UoKTsKICAgICAgICBjb25zdCBoYXkgPSAodHlwZSA9PT0gJ2ltYWdlJyA/IFN0cmluZyhjLmZh
dlRpdGxlIHx8ICcnKSA6IGNsaXBTZWFyY2hIYXkoYykpLnRvTG93ZXJDYXNlKCk7CiAgICAgICAgcmV0
dXJuIHRlcm1MLmV2ZXJ5KHQgPT4gaGF5LmluY2x1ZGVzKHQpKTsKICAgIH0KICAgIGZ1bmN0aW9uIGZp
bHRlcihjbGlwcywgdGFiLCBxKSB7CiAgICAgICAgLy8g5Li75py65bey6L+H5ruk5pe25LuN5YGa5YmN
56uv5YWc5bqV77ya6YG/5YWN56ue5oCB5o6o5p2l5pyq5ZG95Lit6KGMCiAgICAgICAgY29uc3QgdGVy
bXMgPSBxdWVyeVRlcm1zKHEpOwogICAgICAgIGlmICghdGVybXMubGVuZ3RoKSByZXR1cm4gY2xpcHM7
CiAgICAgICAgY29uc3QgdGVybUwgPSB0ZXJtcy5tYXAodCA9PiB0LnRvTG93ZXJDYXNlKCkpOwogICAg
ICAgIGNvbnN0IG1hdGNoZWRHcm91cHMgPSBuZXcgU2V0KCk7CiAgICAgICAgZm9yIChjb25zdCBjIG9m
IGNsaXBzKSB7CiAgICAgICAgICAgIGlmICghY2xpcE1hdGNoZXNTZWFyY2goYywgdGVybUwpKSBjb250
aW51ZTsKICAgICAgICAgICAgY29uc3QgZ2lkID0gU3RyaW5nKGMgJiYgYy5mYXZHcm91cCB8fCAnJyku
dHJpbSgpOwogICAgICAgICAgICBpZiAoZ2lkKSBtYXRjaGVkR3JvdXBzLmFkZChnaWQpOwogICAgICAg
IH0KICAgICAgICAvLyDlkIjlubbnu4TvvJrlhbPplK7lrZflj6/og73liIbmlaPlnKjkuI3lkIzooYzv
vIjmoIfpopgv5q2j5paH77yJCiAgICAgICAgY29uc3QgYnlHcm91cCA9IG5ldyBNYXAoKTsKICAgICAg
ICBmb3IgKGNvbnN0IGMgb2YgY2xpcHMpIHsKICAgICAgICAgICAgY29uc3QgZ2lkID0gU3RyaW5nKGMg
JiYgYy5mYXZHcm91cCB8fCAnJykudHJpbSgpOwogICAgICAgICAgICBpZiAoIWdpZCkgY29udGludWU7
CiAgICAgICAgICAgIGlmICghYnlHcm91cC5oYXMoZ2lkKSkgYnlHcm91cC5zZXQoZ2lkLCBbXSk7CiAg
ICAgICAgICAgIGJ5R3JvdXAuZ2V0KGdpZCkucHVzaChjKTsKICAgICAgICB9CiAgICAgICAgZm9yIChj
b25zdCBbZ2lkLCBtZW1iZXJzXSBvZiBieUdyb3VwKSB7CiAgICAgICAgICAgIGlmIChtYXRjaGVkR3Jv
dXBzLmhhcyhnaWQpKSBjb250aW51ZTsKICAgICAgICAgICAgY29uc3QgdW5pb24gPSBtZW1iZXJzLm1h
cChjID0+IHsKICAgICAgICAgICAgICAgIGNvbnN0IHR5cGUgPSBTdHJpbmcoYy50eXBlIHx8ICcnKS50
b0xvd2VyQ2FzZSgpOwogICAgICAgICAgICAgICAgcmV0dXJuICh0eXBlID09PSAnaW1hZ2UnID8gU3Ry
aW5nKGMuZmF2VGl0bGUgfHwgJycpIDogY2xpcFNlYXJjaEhheShjKSkudG9Mb3dlckNhc2UoKTsKICAg
ICAgICAgICAgfSkuam9pbignICcpOwogICAgICAgICAgICBpZiAodGVybUwuZXZlcnkodCA9PiB1bmlv
bi5pbmNsdWRlcyh0KSkpCiAgICAgICAgICAgICAgICBtYXRjaGVkR3JvdXBzLmFkZChnaWQpOwogICAg
ICAgIH0KICAgICAgICByZXR1cm4gY2xpcHMuZmlsdGVyKGMgPT4gewogICAgICAgICAgICBpZiAoY2xp
cE1hdGNoZXNTZWFyY2goYywgdGVybUwpKSByZXR1cm4gdHJ1ZTsKICAgICAgICAgICAgY29uc3QgZ2lk
ID0gU3RyaW5nKGMgJiYgYy5mYXZHcm91cCB8fCAnJykudHJpbSgpOwogICAgICAgICAgICByZXR1cm4g
Z2lkICYmIG1hdGNoZWRHcm91cHMuaGFzKGdpZCk7CiAgICAgICAgfSk7CiAgICB9CgogICAgZnVuY3Rp
b24gbWFya1Bhc3RlZExvY2FsKGlkcykgewogICAgICAgIGNvbnN0IGxpc3QgPSBBcnJheS5pc0FycmF5
KGlkcykgPyBpZHMgOiBbaWRzXTsKICAgICAgICBpZiAobGlzdC5sZW5ndGgpCiAgICAgICAgICAgIHJl
bWVtYmVyTGFzdFBhc3RlKGxpc3RbbGlzdC5sZW5ndGggLSAxXSk7CiAgICAgICAgY29uc3QgYmFkZ2VI
dG1sID0gYDxzdmcgdmlld0JveD0iMCAwIDE2IDE2IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRD
b2xvciIgc3Ryb2tlLXdpZHRoPSIyLjQiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVq
b2luPSJyb3VuZCI+PHBvbHlsaW5lIHBvaW50cz0iMy41IDguNSA2LjUgMTEuNSAxMi41IDQuNSIvPjwv
c3ZnPmA7CiAgICAgICAgbGlzdC5mb3JFYWNoKGlkID0+IHsKICAgICAgICAgICAgY29uc3QgYyA9IGFs
bENsaXBzLmZpbmQoeCA9PiAreC5pZCA9PT0gK2lkKTsKICAgICAgICAgICAgaWYgKGMpIGMucGFzdGVk
ID0gdHJ1ZTsKICAgICAgICAgICAgY29uc3QgaWNvID0gbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5pdG1b
ZGF0YS1pZD0iJyArIGlkICsgJyJdIC5pLWljbycpOwogICAgICAgICAgICBpZiAoaWNvICYmICFpY28u
cXVlcnlTZWxlY3RvcignLmktdXNlZCcpKSB7CiAgICAgICAgICAgICAgICBjb25zdCBiYWRnZSA9IGRv
Y3VtZW50LmNyZWF0ZUVsZW1lbnQoJ3NwYW4nKTsKICAgICAgICAgICAgICAgIGJhZGdlLmNsYXNzTmFt
ZSA9ICdpLXVzZWQnOwogICAgICAgICAgICAgICAgYmFkZ2UudGl0bGUgPSAn5bey57KY6LS0JzsKICAg
ICAgICAgICAgICAgIGJhZGdlLmlubmVySFRNTCA9IGJhZGdlSHRtbDsKICAgICAgICAgICAgICAgIGlj
by5hcHBlbmRDaGlsZChiYWRnZSk7CiAgICAgICAgICAgIH0KICAgICAgICB9KTsKICAgIH0KCiAgICBj
b25zdCBsaXN0RWwgID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2xpc3QnKTsKICAgIGNvbnN0IGVt
cHR5RWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZW1wdHknKTsKICAgIGNvbnN0IHNrZWxFbCAg
PSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2tlbCcpOwogICAgY29uc3QgYnRuVG9wICA9IGRvY3Vt
ZW50LmdldEVsZW1lbnRCeUlkKCdidG4tdG9wJyk7CiAgICBmdW5jdGlvbiBzZXRCb290TG9hZGluZyhv
bikgewogICAgICAgIGJvb3RMb2FkaW5nID0gISFvbjsKICAgICAgICBpZiAoYm9vdExvYWRpbmcpIHdp
bmRvdy5fX3NrZWxTaW5jZSA9IERhdGUubm93KCk7CiAgICAgICAgaWYgKHNrZWxFbCkgc2tlbEVsLmNs
YXNzTGlzdC50b2dnbGUoJ29uJywgYm9vdExvYWRpbmcpOwogICAgICAgIGlmIChib290TG9hZGluZyAm
JiBlbXB0eUVsKSBlbXB0eUVsLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgY29uc3QgYXBw
ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2FwcCcpOwogICAgICAgIGlmIChhcHApIGFwcC5jbGFz
c0xpc3QudG9nZ2xlKCdib290LWxvYWRpbmcnLCBib290TG9hZGluZyk7CiAgICB9CiAgICAvKiogV2Fp
dCBmb3IgaG9zdCBkYXRhLiBFbXB0eSBsaXN0IOKGknNrZWxldG9uIG5vdyAobm8gYmxhbmspLiBIYXMg
Y29udGVudCDihpJkZWxheS4gKi8KICAgIGZ1bmN0aW9uIHNjaGVkdWxlRGVsYXllZFNrZWwoKSB7CiAg
ICAgICAgd2FpdGluZ0RhdGEgPSB0cnVlOwogICAgICAgIHdpbmRvdy5fX2RhdGFSZWFkeSA9IGZhbHNl
OwogICAgICAgIGlmIChlbXB0eUVsKSBlbXB0eUVsLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAg
ICAgaWYgKHdpbmRvdy5fX3BlbmRpbmdTa2VsVGltZXIpIHsKICAgICAgICAgICAgY2xlYXJUaW1lb3V0
KHdpbmRvdy5fX3BlbmRpbmdTa2VsVGltZXIpOwogICAgICAgICAgICB3aW5kb3cuX19wZW5kaW5nU2tl
bFRpbWVyID0gMDsKICAgICAgICB9CiAgICAgICAgd2luZG93Ll9fcGVuZGluZ1NrZWxTaW5jZSA9IERh
dGUubm93KCk7CiAgICAgICAgY29uc3QgaGFzUGFpbnQgPSAoYWxsQ2xpcHMgJiYgYWxsQ2xpcHMubGVu
Z3RoID4gMCkKICAgICAgICAgICAgfHwgISEobGlzdEVsICYmIGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcu
aXRtJykpOwogICAgICAgIGlmICghaGFzUGFpbnQpIHsKICAgICAgICAgICAgLy8gTm90aGluZyBvbiBz
Y3JlZW4g4oCUc2hvdyBza2VsZXRvbiBpbW1lZGlhdGVseSBzbyBwYW5lbCBpcyBuZXZlciBibGFuawog
ICAgICAgICAgICBzZXRCb290TG9hZGluZyh0cnVlKTsKICAgICAgICAgICAgdHJ5IHsgcmVuZGVyKCk7
IH0gY2F0Y2gge30KICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICAvLyBBbHJlYWR5
IHNob3dpbmcgcm93cyDigJRvbmx5IHN3YXAgdG8gc2tlbGV0b24gaWYgcmVmcmVzaCBpcyBzbG93CiAg
ICAgICAgd2luZG93Ll9fcGVuZGluZ1NrZWxUaW1lciA9IHNldFRpbWVvdXQoKCkgPT4gewogICAgICAg
ICAgICB3aW5kb3cuX19wZW5kaW5nU2tlbFRpbWVyID0gMDsKICAgICAgICAgICAgaWYgKHdhaXRpbmdE
YXRhICYmICF3aW5kb3cuX19kYXRhUmVhZHkpIHsKICAgICAgICAgICAgICAgIHNldEJvb3RMb2FkaW5n
KHRydWUpOwogICAgICAgICAgICAgICAgdHJ5IHsgcmVuZGVyKCk7IH0gY2F0Y2gge30KICAgICAgICAg
ICAgfQogICAgICAgIH0sIFNLRUxfREVMQVlfTVMpOwogICAgfQogICAgZnVuY3Rpb24gY2xlYXJXYWl0
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
c3RFbC5zY3JvbGxUb3AgPiA0OCk7CiAgICB9CiAgICBmdW5jdGlvbiBvbkxpc3RTY3JvbGwoKSB7CiAg
ICAgICAgaGlkZVBhdGhUaXAoKTsKICAgICAgICB1cGRhdGVUb3BCdG4oKTsKICAgICAgICBpZiAobG9h
ZGluZ01vcmUpIHJldHVybjsKICAgICAgICAvLyDot53nprvlupXpg6ggMjQwcHgg6Kem5Y+R5Yqg6L29
5pu05aSa77yM5q+U5Y6f5p2lIDEwMHB4IOabtOeos++8m+W/q+mAn+a7muWKqOaXtuS4jeS8mgogICAg
ICAgIC8vIOi/nue7reinpuWPkSByZXF1ZXN0TW9yZe+8iOW3sueUqCBsb2FkaW5nTW9yZSDpmLLph43l
haXvvIzkvYbmraTlpITku43pgb/lhY3mipbliqjvvInjgIIKICAgICAgICBpZiAobGlzdEVsLnNjcm9s
bFRvcCArIGxpc3RFbC5jbGllbnRIZWlnaHQgPj0gbGlzdEVsLnNjcm9sbEhlaWdodCAtIDI0MCkKICAg
ICAgICAgICAgcmVxdWVzdE1vcmUoKTsKICAgIH0KICAgIGxpc3RFbC5hZGRFdmVudExpc3RlbmVyKCdz
Y3JvbGwnLCBvbkxpc3RTY3JvbGwsIHsgcGFzc2l2ZTogdHJ1ZSB9KTsKICAgIGJ0blRvcC5hZGRFdmVu
dExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAg
ICAgbGlzdEVsLnNjcm9sbFRvKHsgdG9wOiAwLCBiZWhhdmlvcjogJ3Ntb290aCcgfSk7CiAgICB9KTsK
CiAgICBmdW5jdGlvbiB2aXNpYmxlTGlzdCgpIHsKICAgICAgICBjb25zdCBxID0gU3RyaW5nKHF1ZXJ5
IHx8ICcnKS50cmltKCk7CiAgICAgICAgLy8gSG9zdCBhbHJlYWR5IGZpbHRlcmVkK2V4cGFuZGVkIGZv
ciB0aGlzIGV4YWN0IHF1ZXJ5IOKAlCBkb24ndCByZS1maWx0ZXIgKGF2b2lkcyBmbGFzaCAvIGRyb3Bw
ZWQgZmF2IGdyb3VwcykKICAgICAgICBpZiAocSAmJiB3aW5kb3cuX19ob3N0RmlsdGVyZWQgJiYgd2lu
ZG93Ll9faG9zdEZpbHRlclEgPT09IHEpCiAgICAgICAgICAgIHJldHVybiBhbGxDbGlwczsKICAgICAg
ICByZXR1cm4gZmlsdGVyKGFsbENsaXBzLCBjdXJUYWIsIHF1ZXJ5KTsKICAgIH0KICAgIGZ1bmN0aW9u
IGVzY0h0bWwocykgewogICAgICAgIHJldHVybiBTdHJpbmcocyA/PyAnJykucmVwbGFjZSgvJi9nLCcm
YW1wOycpLnJlcGxhY2UoLzwvZywnJmx0OycpLnJlcGxhY2UoLz4vZywnJmd0OycpLnJlcGxhY2UoLyIv
ZywnJnF1b3Q7Jyk7CiAgICB9CiAgICBmdW5jdGlvbiBxdWVyeVRlcm1zKHEpIHsKICAgICAgICBjb25z
dCBvdXQgPSBbXTsKICAgICAgICBmb3IgKGNvbnN0IHNlZyBvZiBTdHJpbmcocSB8fCAnJykuc3BsaXQo
J3wnKSkgewogICAgICAgICAgICBjb25zdCBzID0gc2VnLnRyaW0oKTsKICAgICAgICAgICAgaWYgKCFz
KSBjb250aW51ZTsKICAgICAgICAgICAgY29uc3Qgd29yZHMgPSBzLnNwbGl0KC9ccysvKS5maWx0ZXIo
Qm9vbGVhbik7CiAgICAgICAgICAgIGlmICh3b3Jkcy5sZW5ndGgpIG91dC5wdXNoKC4uLndvcmRzKTsK
ICAgICAgICB9CiAgICAgICAgcmV0dXJuIG91dDsKICAgIH0KICAgIGZ1bmN0aW9uIGhsSHRtbCh0ZXh0
KSB7CiAgICAgICAgY29uc3QgdGVybXMgPSBxdWVyeVRlcm1zKHF1ZXJ5KTsKICAgICAgICBjb25zdCBz
ID0gU3RyaW5nKHRleHQgPz8gJycpOwogICAgICAgIGlmICghdGVybXMubGVuZ3RoKSByZXR1cm4gZXNj
SHRtbChzKTsKICAgICAgICBjb25zdCBsb3dlciA9IHMudG9Mb3dlckNhc2UoKTsKICAgICAgICBjb25z
dCB0ZXJtTCA9IHRlcm1zLm1hcCh0ID0+IHQudG9Mb3dlckNhc2UoKSk7CiAgICAgICAgbGV0IG91dCA9
ICcnLCBpID0gMDsKICAgICAgICB3aGlsZSAoaSA8IHMubGVuZ3RoKSB7CiAgICAgICAgICAgIGxldCBi
ZXN0SiA9IC0xLCBiZXN0TGVuID0gMDsKICAgICAgICAgICAgZm9yIChsZXQgdGkgPSAwOyB0aSA8IHRl
cm1MLmxlbmd0aDsgdGkrKykgewogICAgICAgICAgICAgICAgY29uc3QgdCA9IHRlcm1MW3RpXTsKICAg
ICAgICAgICAgICAgIGlmICghdCkgY29udGludWU7CiAgICAgICAgICAgICAgICBjb25zdCBqID0gbG93
ZXIuaW5kZXhPZih0LCBpKTsKICAgICAgICAgICAgICAgIGlmIChqIDwgMCkgY29udGludWU7CiAgICAg
ICAgICAgICAgICBpZiAoYmVzdEogPCAwIHx8IGogPCBiZXN0SiB8fCAoaiA9PT0gYmVzdEogJiYgdC5s
ZW5ndGggPiBiZXN0TGVuKSkgewogICAgICAgICAgICAgICAgICAgIGJlc3RKID0gajsgYmVzdExlbiA9
IHQubGVuZ3RoOwogICAgICAgICAgICAgICAgfQogICAgICAgICAgICB9CiAgICAgICAgICAgIGlmIChi
ZXN0SiA8IDApIHsgb3V0ICs9IGVzY0h0bWwocy5zbGljZShpKSk7IGJyZWFrOyB9CiAgICAgICAgICAg
IG91dCArPSBlc2NIdG1sKHMuc2xpY2UoaSwgYmVzdEopKTsKICAgICAgICAgICAgb3V0ICs9ICc8bWFy
ayBjbGFzcz0icS1obCI+JyArIGVzY0h0bWwocy5zbGljZShiZXN0SiwgYmVzdEogKyBiZXN0TGVuKSkg
KyAnPC9tYXJrPic7CiAgICAgICAgICAgIGkgPSBiZXN0SiArIE1hdGgubWF4KDEsIGJlc3RMZW4pOwog
ICAgICAgIH0KICAgICAgICByZXR1cm4gb3V0OwogICAgfQogICAgZnVuY3Rpb24gc2V0SGxUZXh0KGVs
LCB0ZXh0KSB7CiAgICAgICAgaWYgKCFlbCkgcmV0dXJuOwogICAgICAgIGNvbnN0IHEgPSBTdHJpbmco
cXVlcnkgfHwgJycpLnRyaW0oKTsKICAgICAgICBpZiAoIXEpIHsKICAgICAgICAgICAgZWwuY2xhc3NM
aXN0LnJlbW92ZSgnaGFzLWhsJyk7CiAgICAgICAgICAgIGVsLnRleHRDb250ZW50ID0gdGV4dCA9PSBu
dWxsID8gJycgOiBTdHJpbmcodGV4dCk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAg
ICAgZWwuY2xhc3NMaXN0LmFkZCgnaGFzLWhsJyk7CiAgICAgICAgZWwuaW5uZXJIVE1MID0gaGxIdG1s
KHRleHQpOwogICAgfQoKCiAgICBmdW5jdGlvbiBhcHBseVRhYlN3aXRjaEFuaW0oKSB7CiAgICAgICAg
aWYgKCF0YWJTd2l0Y2hBbmltRGlyIHx8ICFsaXN0RWwpIHJldHVybjsKICAgICAgICBpZiAoIWxpc3RF
bC5xdWVyeVNlbGVjdG9yKCcuaXRtLCAjZW1wdHkub24sICNsaXN0LW1vcmUnKSkKICAgICAgICAgICAg
cmV0dXJuOwogICAgICAgIGNvbnN0IGRpciA9IHRhYlN3aXRjaEFuaW1EaXI7CiAgICAgICAgdGFiU3dp
dGNoQW5pbURpciA9IDA7CiAgICAgICAgbGlzdEVsLmNsYXNzTGlzdC5yZW1vdmUoJ3RhYi1pbi1scics
ICd0YWItaW4tcmwnKTsKICAgICAgICB2b2lkIGxpc3RFbC5vZmZzZXRXaWR0aDsKICAgICAgICBsaXN0
RWwuY2xhc3NMaXN0LmFkZChkaXIgPiAwID8gJ3RhYi1pbi1scicgOiAndGFiLWluLXJsJyk7CiAgICAg
ICAgY2xlYXJUaW1lb3V0KGxpc3RFbC5fdGFiQW5pbVRpbWVyKTsKICAgICAgICBsaXN0RWwuX3RhYkFu
aW1UaW1lciA9IHNldFRpbWVvdXQoKCkgPT4gewogICAgICAgICAgICBsaXN0RWwuY2xhc3NMaXN0LnJl
bW92ZSgndGFiLWluLWxyJywgJ3RhYi1pbi1ybCcpOwogICAgICAgIH0sIDQwMCk7CiAgICB9CgogICAg
ZnVuY3Rpb24gdGFiSW5kZXgodGFiKSB7CiAgICAgICAgY29uc3QgaSA9IFRBQl9PUkRFUi5pbmRleE9m
KHRhYik7CiAgICAgICAgcmV0dXJuIGkgPj0gMCA/IGkgOiAwOwogICAgfQoKICAgIGZ1bmN0aW9uIG1v
dmVUYWJJbmsoaW5zdGFudCwgdGFyZ2V0RWwpIHsKICAgICAgICBjb25zdCBpbmsgPSBkb2N1bWVudC5n
ZXRFbGVtZW50QnlJZCgndGFiLWluaycpOwogICAgICAgIGNvbnN0IHRhYnMgPSBkb2N1bWVudC5nZXRF
bGVtZW50QnlJZCgndGFicycpOwogICAgICAgIGNvbnN0IGVsID0gdGFyZ2V0RWwgfHwgZG9jdW1lbnQu
cXVlcnlTZWxlY3RvcignI3RhYnMgLnRhYi5vbicpOwogICAgICAgIGlmICghaW5rIHx8ICF0YWJzIHx8
ICFlbCkgcmV0dXJuOwogICAgICAgIGNvbnN0IHRyID0gdGFicy5nZXRCb3VuZGluZ0NsaWVudFJlY3Qo
KTsKICAgICAgICBjb25zdCByID0gZWwuZ2V0Qm91bmRpbmdDbGllbnRSZWN0KCk7CiAgICAgICAgY29u
c3QgeCA9IHIubGVmdCAtIHRyLmxlZnQ7CiAgICAgICAgY29uc3QgaCA9IE1hdGgubWF4KDIwLCBNYXRo
LnJvdW5kKHIuaGVpZ2h0KSk7CiAgICAgICAgY29uc3QgeSA9IHIudG9wIC0gdHIudG9wOwogICAgICAg
IGNvbnN0IHcgPSBNYXRoLm1heCgyNCwgci53aWR0aCk7CiAgICAgICAgY29uc3QgcG9zID0gJ3RyYW5z
bGF0ZTNkKCcgKyB4ICsgJ3B4LCcgKyB5ICsgJ3B4LDApJzsKICAgICAgICBpbmsuc3R5bGUudHJhbnNm
b3JtT3JpZ2luID0gJ2NlbnRlciBib3R0b20nOwogICAgICAgIGluay5zdHlsZS53aWR0aCA9IHcgKyAn
cHgnOwogICAgICAgIGluay5zdHlsZS5oZWlnaHQgPSBoICsgJ3B4JzsKICAgICAgICBpZiAoaW5zdGFu
dCkgewogICAgICAgICAgICBpbmsuc3R5bGUudHJhbnNpdGlvbiA9ICdub25lJzsKICAgICAgICAgICAg
aW5rLmNsYXNzTGlzdC5yZW1vdmUoJ3NxdWFzaCcpOwogICAgICAgICAgICBpbmsuc3R5bGUudHJhbnNm
b3JtID0gcG9zICsgJyBzY2FsZVgoMSknOwogICAgICAgICAgICBpbmsub2Zmc2V0SGVpZ2h0OwogICAg
ICAgICAgICBpbmsuc3R5bGUudHJhbnNpdGlvbiA9ICcnOwogICAgICAgICAgICByZXR1cm47CiAgICAg
ICAgfQogICAgICAgIC8vIFNuYXAgdG8gaG92ZXJlZCB0YWIsIGV4cGFuZCBmcm9tIGJvdHRvbS1jZW50
ZXIg4oCUIG5vIHNsaWRpbmcgYmV0d2VlbiB0YWJzCiAgICAgICAgaW5rLnN0eWxlLnRyYW5zaXRpb24g
PSAnbm9uZSc7CiAgICAgICAgaW5rLnN0eWxlLnRyYW5zZm9ybSA9IHBvcyArICcgc2NhbGVYKDAuMDAx
KSc7CiAgICAgICAgaW5rLm9mZnNldEhlaWdodDsKICAgICAgICBpbmsuc3R5bGUudHJhbnNpdGlvbiA9
ICcnOwogICAgICAgIGluay5jbGFzc0xpc3QuYWRkKCdzcXVhc2gnKTsKICAgICAgICBpbmsuc3R5bGUu
dHJhbnNmb3JtID0gcG9zICsgJyBzY2FsZVgoMSknOwogICAgICAgIGNsZWFyVGltZW91dChpbmsuX3Nx
dWFzaFRpbWVyKTsKICAgICAgICBpbmsuX3NxdWFzaFRpbWVyID0gc2V0VGltZW91dCgoKSA9PiBpbmsu
Y2xhc3NMaXN0LnJlbW92ZSgnc3F1YXNoJyksIDM0MCk7CiAgICB9CiAgICBmdW5jdGlvbiBtYXJrVGFi
KHRhYiwgaW5zdGFudCkgewogICAgICAgIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJyN0YWJzIC50
YWInKS5mb3JFYWNoKGVsID0+CiAgICAgICAgICAgIGVsLmNsYXNzTGlzdC50b2dnbGUoJ29uJywgZWwu
ZGF0YXNldC50YWIgPT09IHRhYikpOwogICAgICAgIG1vdmVUYWJJbmsoISFpbnN0YW50KTsKICAgIH0K
ICAgIGZ1bmN0aW9uIGJpbmRUYWJJbmtIb3ZlcigpIHsKICAgICAgICBjb25zdCB0YWJzID0gZG9jdW1l
bnQuZ2V0RWxlbWVudEJ5SWQoJ3RhYnMnKTsKICAgICAgICBpZiAoIXRhYnMgfHwgdGFicy5faW5rSG92
ZXJCb3VuZCkgcmV0dXJuOwogICAgICAgIHRhYnMuX2lua0hvdmVyQm91bmQgPSB0cnVlOwogICAgICAg
IHRhYnMuYWRkRXZlbnRMaXN0ZW5lcigncG9pbnRlcm92ZXInLCBlID0+IHsKICAgICAgICAgICAgY29u
c3QgdGFiID0gZS50YXJnZXQuY2xvc2VzdCgnLnRhYicpOwogICAgICAgICAgICBpZiAoIXRhYiB8fCAh
dGFicy5jb250YWlucyh0YWIpKSByZXR1cm47CiAgICAgICAgICAgIG1vdmVUYWJJbmsoZmFsc2UsIHRh
Yik7CiAgICAgICAgfSk7CiAgICAgICAgdGFicy5hZGRFdmVudExpc3RlbmVyKCdwb2ludGVybGVhdmUn
LCBlID0+IHsKICAgICAgICAgICAgaWYgKGUucmVsYXRlZFRhcmdldCAmJiB0YWJzLmNvbnRhaW5zKGUu
cmVsYXRlZFRhcmdldCkpIHJldHVybjsKICAgICAgICAgICAgbW92ZVRhYkluayhmYWxzZSk7CiAgICAg
ICAgfSk7CiAgICB9CmZ1bmN0aW9uIHNldFRhYih0YWIpIHsKICAgICAgICBpZiAodGFiID09PSBjdXJU
YWIpIHJldHVybjsKICAgICAgICBjb25zdCBmcm9tID0gdGFiSW5kZXgoY3VyVGFiKTsKICAgICAgICBj
b25zdCB0byA9IHRhYkluZGV4KHRhYik7CiAgICAgICAgdGFiU3dpdGNoQW5pbURpciA9IHRvID4gZnJv
bSA/IDEgOiAodG8gPCBmcm9tID8gLTEgOiAwKTsKICAgICAgICBjdXJUYWIgPSB0YWI7CiAgICAgICAg
bG9hZGluZ01vcmUgPSBmYWxzZTsKICAgICAgICBtYXJrVGFiKHRhYik7CgogICAgICAgIC8vIEtlZXAg
c2VhcmNoICJ0b2RheSIgZmlsdGVyIGluIHN5bmMgd2hlbiBzZWFyY2ggaXMgb3BlbgogICAgICAgIHRy
eSB7CiAgICAgICAgICAgIGNvbnN0IHdyYXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNo
LXdyYXAnKTsKICAgICAgICAgICAgY29uc3QgYnRuVG9kYXkgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJ
ZCgnYnRuLXRvZGF5Jyk7CiAgICAgICAgICAgIGlmICh3cmFwICYmIHdyYXAuY2xhc3NMaXN0LmNvbnRh
aW5zKCdvcGVuJykpIHsKICAgICAgICAgICAgICAgIGNvbnN0IHdhbnRUb2RheSA9IGZhbHNlOwogICAg
ICAgICAgICAgICAgaWYgKHRvZGF5T25seSAhPT0gd2FudFRvZGF5KSB7CiAgICAgICAgICAgICAgICAg
ICAgdG9kYXlPbmx5ID0gd2FudFRvZGF5OwogICAgICAgICAgICAgICAgICAgIGlmIChidG5Ub2RheSkg
YnRuVG9kYXkuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCB0b2RheU9ubHkpOwogICAgICAgICAgICAgICAg
fQogICAgICAgICAgICB9CiAgICAgICAgfSBjYXRjaCB7fQoKICAgICAgICBzZWxlY3RlZElkID0gbnVs
bDsKICAgICAgICBtdWx0aUlkcyA9IFtdOwogICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSAwOwogICAg
ICAgIGNvbnN0IGhpdCA9IHZpZXdNZW0uZ2V0KHZpZXdNZW1LZXkodGFiLCBxdWVyeSwgdG9kYXlPbmx5
KSk7CiAgICAgICAgaWYgKGhpdCAmJiBBcnJheS5pc0FycmF5KGhpdC5pdGVtcykgJiYgaGl0Lml0ZW1z
Lmxlbmd0aCkgewogICAgICAgICAgICBhbGxDbGlwcyA9IGhpdC5pdGVtcy5zbGljZSgpOwogICAgICAg
ICAgICBkaXNrVG90YWwgPSBOdW1iZXIoaGl0LnRvdGFsKSB8fCBoaXQuaXRlbXMubGVuZ3RoOwogICAg
ICAgICAgICB3aW5kb3cuX193YWl0aW5nVmlldyA9IGZhbHNlOwogICAgICAgICAgICBjbGVhcldhaXRp
bmdEYXRhKCk7CiAgICAgICAgICAgIHdpbmRvdy5fX2RhdGFSZWFkeSA9IHRydWU7CiAgICAgICAgICAg
IGhvc3RQdXNoZWRPbmNlID0gdHJ1ZTsKICAgICAgICAgICAgc2F3Tm9uRW1wdHkgPSB0cnVlOwogICAg
ICAgICAgICByZW5kZXIoKTsKICAgICAgICAgICAgYXBwbHlUYWJTd2l0Y2hBbmltKCk7CiAgICAgICAg
ICAgIC8vIE1lbW9yeSBwYWludCBmaXJzdCDigJRiYWNrZ3JvdW5kIHNvZnQtc3luYyBrZWVwcyBBSEsg
aW4gc3RlcCB3aXRob3V0IGRvdWJsZSByZWRyYXcKICAgICAgICAgICAgc29mdFJlcXVlc3RWaWV3KCk7
CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgYWxsQ2xpcHMgPSBbXTsKICAgICAg
ICBkaXNrVG90YWwgPSAwOwogICAgICAgIHdpbmRvdy5fX3dhaXRpbmdWaWV3ID0gdHJ1ZTsKICAgICAg
ICBzY2hlZHVsZURlbGF5ZWRTa2VsKCk7CiAgICAgICAgcmVxdWVzdFZpZXcoKTsKICAgICAgICByZW5k
ZXIoKTsKICAgICAgICBhcHBseVRhYlN3aXRjaEFuaW0oKTsKICAgIH0KCiAgICBtb3ZlVGFiSW5rKHRy
dWUpOwogICAgYmluZFRhYklua0hvdmVyKCk7CiAgICB0cnkgeyBuZXcgUmVzaXplT2JzZXJ2ZXIoKCkg
PT4gbW92ZVRhYkluayh0cnVlKSkub2JzZXJ2ZShkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGFicycp
KTsgfSBjYXRjaCB7fQogICAgd2luZG93LmFkZEV2ZW50TGlzdGVuZXIoJ3Jlc2l6ZScsICgpID0+IG1v
dmVUYWJJbmsodHJ1ZSkpOwoKICAgIGZ1bmN0aW9uIHVwZGF0ZU1vcmVGb290ZXIodG90YWwpIHsKICAg
ICAgICBsZXQgbW9yZUVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2xpc3QtbW9yZScpOwogICAg
ICAgIGNvbnN0IGxvYWRlZCA9IGFsbENsaXBzLmxlbmd0aDsKICAgICAgICBpZiAobG9hZGVkID49IHRv
dGFsKSB7CiAgICAgICAgICAgIGlmIChtb3JlRWwpIG1vcmVFbC5yZW1vdmUoKTsKICAgICAgICAgICAg
cmV0dXJuOwogICAgICAgIH0KICAgICAgICBpZiAoIW1vcmVFbCkgewogICAgICAgICAgICBtb3JlRWwg
PSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgbW9yZUVsLmlkID0gJ2xp
c3QtbW9yZSc7CiAgICAgICAgICAgIG1vcmVFbC5jbGFzc05hbWUgPSAnbGlzdC1tb3JlJzsKICAgICAg
ICAgICAgbGlzdEVsLmFwcGVuZENoaWxkKG1vcmVFbCk7CiAgICAgICAgfQogICAgICAgIG1vcmVFbC50
ZXh0Q29udGVudCA9ICfnu6fnu63kuIvmu5Hku47no4Hnm5jliqDovb3vvIgnICsgbG9hZGVkICsgJy8n
ICsgdG90YWwgKyAn77yJJzsKICAgIH0KCiAgICBmdW5jdGlvbiBuYXZMaXN0KCkgewogICAgICAgIGNv
bnN0IGJsb2NrcyA9IGJ1aWxkUGlubmVkQmxvY2tzKHZpc2libGVMaXN0KCkpOwogICAgICAgIGNvbnN0
IG91dCA9IFtdOwogICAgICAgIGZvciAoY29uc3QgYiBvZiBibG9ja3MpIHsKICAgICAgICAgICAgaWYg
KCFiIHx8ICFiLml0ZW1zKSBjb250aW51ZTsKICAgICAgICAgICAgZm9yIChjb25zdCBjIG9mIGIuaXRl
bXMpIG91dC5wdXNoKGMpOwogICAgICAgIH0KICAgICAgICByZXR1cm4gb3V0OwogICAgfQoKICAgIGZ1
bmN0aW9uIHNlbGVjdEJ5SW5kZXgoaWR4KSB7CiAgICAgICAgY29uc3QgdmlzID0gbmF2TGlzdCgpOwog
ICAgICAgIGlmICghdmlzLmxlbmd0aCkgcmV0dXJuOwogICAgICAgIGlkeCA9IE1hdGgubWF4KDAsIE1h
dGgubWluKHZpcy5sZW5ndGggLSAxLCBpZHgpKTsKICAgICAgICBpZiAoaWR4ID49IHZpcy5sZW5ndGgg
LSAxICYmIGFsbENsaXBzLmxlbmd0aCA8IGRpc2tUb3RhbCkKICAgICAgICAgICAgcmVxdWVzdE1vcmUo
KTsKICAgICAgICBzZWxlY3RlZElkID0gdmlzW01hdGgubWluKGlkeCwgdmlzLmxlbmd0aCAtIDEpXS5p
ZDsKICAgICAgICByYW5nZUFuY2hvcklkID0gc2VsZWN0ZWRJZDsKICAgICAgICByYW5nZUFuY2hvckNs
aWNrZWQgPSBmYWxzZTsKICAgICAgICBpZiAoK3NlbGVjdGVkSWQgIT09ICtsYXN0UGFzdGVJZCkKICAg
ICAgICAgICAgbG9jYXRlQWN0aXZlID0gZmFsc2U7CiAgICAgICAgdXBkYXRlTG9jYXRlQnRuKCk7CiAg
ICAgICAgc3luY0l0ZW1IaWdobGlnaHQoKTsKICAgICAgICBjb25zdCBlbCA9IGxpc3RFbC5xdWVyeVNl
bGVjdG9yKCcubWctcm93W2RhdGEtaWQ9IicgKyBzZWxlY3RlZElkICsgJyJdJykKICAgICAgICAgICAg
fHwgbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5pdG1bZGF0YS1pZD0iJyArIHNlbGVjdGVkSWQgKyAnIl0n
KTsKICAgICAgICBpZiAoZWwpIGVsLnNjcm9sbEludG9WaWV3KHsgYmxvY2s6ICduZWFyZXN0JyB9KTsK
ICAgIH0KCiAgICBmdW5jdGlvbiBzZWxlY3RlZEluZGV4KCkgewogICAgICAgIHJldHVybiBuYXZMaXN0
KCkuZmluZEluZGV4KGMgPT4gYy5pZCA9PSBzZWxlY3RlZElkKTsKICAgIH0KCiAgICBmdW5jdGlvbiBz
eW5jSXRlbUhpZ2hsaWdodCgpIHsKICAgICAgICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcuaXRt
JykuZm9yRWFjaChuID0+IHsKICAgICAgICAgICAgaWYgKG4uY2xhc3NMaXN0LmNvbnRhaW5zKCdpdC1n
cm91cCcpKSB7CiAgICAgICAgICAgICAgICBjb25zdCByb3dzID0gWy4uLm4ucXVlcnlTZWxlY3RvckFs
bCgnLm1nLXJvdycpXTsKICAgICAgICAgICAgICAgIGNvbnN0IGlkcyA9IHJvd3MubWFwKHIgPT4gK3Iu
ZGF0YXNldC5pZCk7CiAgICAgICAgICAgICAgICBjb25zdCBhbnlTZWwgPSBpZHMuaW5jbHVkZXMoK3Nl
bGVjdGVkSWQpIHx8IGlkcy5zb21lKGlkID0+IG11bHRpSWRzLmluY2x1ZGVzKGlkKSk7CiAgICAgICAg
ICAgICAgICBuLmNsYXNzTGlzdC50b2dnbGUoJ3NlbCcsIGFueVNlbCk7CiAgICAgICAgICAgICAgICBu
LmNsYXNzTGlzdC50b2dnbGUoJ211bHRpJywgaWRzLnNvbWUoaWQgPT4gbXVsdGlJZHMuaW5jbHVkZXMo
aWQpKSk7CiAgICAgICAgICAgICAgICByb3dzLmZvckVhY2gociA9PiB7CiAgICAgICAgICAgICAgICAg
ICAgY29uc3QgaWQgPSArci5kYXRhc2V0LmlkOwogICAgICAgICAgICAgICAgICAgIGNvbnN0IGluTXVs
dGkgPSBtdWx0aUlkcy5pbmNsdWRlcyhpZCk7CiAgICAgICAgICAgICAgICAgICAgci5jbGFzc0xpc3Qu
dG9nZ2xlKCdzZWwnLCBpZCA9PSBzZWxlY3RlZElkIHx8IGluTXVsdGkpOwogICAgICAgICAgICAgICAg
ICAgIHIuY2xhc3NMaXN0LnRvZ2dsZSgnbXVsdGknLCBpbk11bHRpKTsKICAgICAgICAgICAgICAgIH0p
OwogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICB9CiAgICAgICAgICAgIGNvbnN0IGlk
ID0gK24uZGF0YXNldC5pZDsKICAgICAgICAgICAgY29uc3QgaW5NdWx0aSA9IG11bHRpSWRzLmluY2x1
ZGVzKGlkKTsKICAgICAgICAgICAgbi5jbGFzc0xpc3QudG9nZ2xlKCdzZWwnLCBpZCA9PSBzZWxlY3Rl
ZElkIHx8IGluTXVsdGkpOwogICAgICAgICAgICBuLmNsYXNzTGlzdC50b2dnbGUoJ211bHRpJywgaW5N
dWx0aSk7CiAgICAgICAgfSk7CiAgICB9CiAgICBmdW5jdGlvbiB1cGRhdGVNdWx0aUJhZGdlKCkgewog
ICAgICAgIGNvbnN0IGVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ211bHRpLWNudCcpOwogICAg
ICAgIGlmIChtdWx0aUlkcy5sZW5ndGggPiAwKSB7CiAgICAgICAgICAgIGVsLnRleHRDb250ZW50ID0g
U3RyaW5nKG11bHRpSWRzLmxlbmd0aCk7CiAgICAgICAgICAgIGVsLmNsYXNzTGlzdC5hZGQoJ29uJyk7
CiAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgZWwuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAg
ICAgICB9CiAgICAgICAgc3luY0l0ZW1IaWdobGlnaHQoKTsKICAgIH0KCiAgICBmdW5jdGlvbiBjbGVh
ck11bHRpKHJlc3RvcmVUb0FuY2hvcikgewogICAgICAgIGNvbnN0IGJhY2tJZCA9ICtyYW5nZUFuY2hv
cklkIHx8IDA7CiAgICAgICAgbXVsdGlJZHMgPSBbXTsKICAgICAgICBpZiAocmVzdG9yZVRvQW5jaG9y
ICYmIGJhY2tJZCkKICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IGJhY2tJZDsKICAgICAgICByYW5nZUFu
Y2hvcklkID0gc2VsZWN0ZWRJZCB8fCAwOwogICAgICAgIHJhbmdlQW5jaG9yQ2xpY2tlZCA9IGZhbHNl
OwogICAgICAgIHVwZGF0ZU11bHRpQmFkZ2UoKTsKICAgICAgICBpZiAocmVzdG9yZVRvQW5jaG9yICYm
IHNlbGVjdGVkSWQpIHsKICAgICAgICAgICAgY29uc3QgZWwgPSBsaXN0RWwucXVlcnlTZWxlY3Rvcign
Lm1nLXJvd1tkYXRhLWlkPSInICsgc2VsZWN0ZWRJZCArICciXScpCiAgICAgICAgICAgICAgICB8fCBs
aXN0RWwucXVlcnlTZWxlY3RvcignLml0bVtkYXRhLWlkPSInICsgc2VsZWN0ZWRJZCArICciXScpOwog
ICAgICAgICAgICBpZiAoZWwpIGVsLnNjcm9sbEludG9WaWV3KHsgYmxvY2s6ICduZWFyZXN0JyB9KTsK
ICAgICAgICB9CiAgICB9CgoKICAgIC8qIHNoaWZ0LXJhbmdlLXNlbGVjdC12MSAqLwogICAgbGV0IHJh
bmdlQW5jaG9ySWQgPSAwOwogICAgbGV0IHJhbmdlQW5jaG9yQ2xpY2tlZCA9IGZhbHNlOwogICAgZnVu
Y3Rpb24gc2VsZWN0UmFuZ2VUbyhpZCkgewogICAgICAgIGlkID0gK2lkOwogICAgICAgIGNvbnN0IGxp
c3QgPSAodHlwZW9mIG5hdkxpc3QgPT09ICdmdW5jdGlvbicgPyBuYXZMaXN0KCkgOiB2aXNpYmxlTGlz
dCgpKTsKICAgICAgICBjb25zdCBiID0gbGlzdC5maW5kSW5kZXgoYyA9PiArYy5pZCA9PT0gaWQpOwog
ICAgICAgIGlmIChiIDwgMCkgcmV0dXJuOwogICAgICAgIGxldCBhbmNob3IgPSArcmFuZ2VBbmNob3JJ
ZDsKICAgICAgICBsZXQgYSA9IGxpc3QuZmluZEluZGV4KGMgPT4gK2MuaWQgPT09IGFuY2hvcik7CiAg
ICAgICAgaWYgKGEgPCAwKSB7CiAgICAgICAgICAgIGFuY2hvciA9ICtzZWxlY3RlZElkIHx8IGlkOwog
ICAgICAgICAgICBhID0gbGlzdC5maW5kSW5kZXgoYyA9PiArYy5pZCA9PT0gYW5jaG9yKTsKICAgICAg
ICB9CiAgICAgICAgaWYgKGEgPCAwKSB7CiAgICAgICAgICAgIHJhbmdlQW5jaG9ySWQgPSBpZDsgc2Vs
ZWN0ZWRJZCA9IGlkOyBtdWx0aUlkcyA9IFtpZF07IHVwZGF0ZU11bHRpQmFkZ2UoKTsgcmV0dXJuOwog
ICAgICAgIH0KICAgICAgICBpZiAoIXJhbmdlQW5jaG9ySWQgfHwgbGlzdC5maW5kSW5kZXgoYyA9PiAr
Yy5pZCA9PT0gK3JhbmdlQW5jaG9ySWQpIDwgMCkKICAgICAgICAgICAgcmFuZ2VBbmNob3JJZCA9IGxp
c3RbYV0uaWQ7CiAgICAgICAgY29uc3QgbG8gPSBNYXRoLm1pbihhLCBiKSwgaGkgPSBNYXRoLm1heChh
LCBiKTsKICAgICAgICBtdWx0aUlkcyA9IFtdOwogICAgICAgIGZvciAobGV0IGkgPSBsbzsgaSA8PSBo
aTsgaSsrKSBtdWx0aUlkcy5wdXNoKCtsaXN0W2ldLmlkKTsKICAgICAgICBzZWxlY3RlZElkID0gaWQ7
CiAgICAgICAgdXBkYXRlTXVsdGlCYWRnZSgpOwogICAgICAgIGNvbnN0IGVsID0gbGlzdEVsLnF1ZXJ5
U2VsZWN0b3IoJy5tZy1yb3dbZGF0YS1pZD0iJyArIHNlbGVjdGVkSWQgKyAnIl0nKSB8fCBsaXN0RWwu
cXVlcnlTZWxlY3RvcignLml0bVtkYXRhLWlkPSInICsgc2VsZWN0ZWRJZCArICciXScpOwogICAgICAg
IGlmIChlbCkgZWwuc2Nyb2xsSW50b1ZpZXcoeyBibG9jazogJ25lYXJlc3QnIH0pOwogICAgfQogICAg
ZnVuY3Rpb24gc2hvd1NyY1RpcChhbmNob3IsIHRleHQpIHsKICAgICAgICB0ZXh0ID0gU3RyaW5nKHRl
eHQgfHwgJycpLnRyaW0oKTsKICAgICAgICBpZiAoIXRleHQpIHJldHVybjsKICAgICAgICBsZXQgdGlw
ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NyYy10aXAnKTsKICAgICAgICBpZiAoIXRpcCkgewog
ICAgICAgICAgICB0aXAgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAg
dGlwLmlkID0gJ3NyYy10aXAnOwogICAgICAgICAgICBkb2N1bWVudC5ib2R5LmFwcGVuZENoaWxkKHRp
cCk7CiAgICAgICAgfQogICAgICAgIHRpcC50ZXh0Q29udGVudCA9IHRleHQ7CiAgICAgICAgdGlwLmNs
YXNzTGlzdC5hZGQoJ3Nob3cnKTsKICAgICAgICBjb25zdCByID0gYW5jaG9yLmdldEJvdW5kaW5nQ2xp
ZW50UmVjdCgpOwogICAgICAgIGNvbnN0IHR3ID0gdGlwLm9mZnNldFdpZHRoIHx8IDE2MDsKICAgICAg
ICBjb25zdCB0aCA9IHRpcC5vZmZzZXRIZWlnaHQgfHwgMjg7CiAgICAgICAgbGV0IGxlZnQgPSByLnJp
Z2h0IC0gdHc7CiAgICAgICAgbGV0IHRvcCA9IHIudG9wIC0gdGggLSA4OwogICAgICAgIGlmIChsZWZ0
IDwgOCkgbGVmdCA9IDg7CiAgICAgICAgaWYgKGxlZnQgKyB0dyA+IHdpbmRvdy5pbm5lcldpZHRoIC0g
OCkgbGVmdCA9IHdpbmRvdy5pbm5lcldpZHRoIC0gdHcgLSA4OwogICAgICAgIGlmICh0b3AgPCA4KSB0
b3AgPSByLmJvdHRvbSArIDg7CiAgICAgICAgdGlwLnN0eWxlLmxlZnQgPSBsZWZ0ICsgJ3B4JzsKICAg
ICAgICB0aXAuc3R5bGUudG9wID0gdG9wICsgJ3B4JzsKICAgICAgICBjbGVhclRpbWVvdXQodGlwLl9o
aWRlVCk7CiAgICAgICAgdGlwLl9oaWRlVCA9IHNldFRpbWVvdXQoKCkgPT4gdGlwLmNsYXNzTGlzdC5y
ZW1vdmUoJ3Nob3cnKSwgMjIwMCk7CiAgICB9CiAgICAvKiBpbWctaG92ZXItcHJldmlldy12OCAqLwog
ICAgbGV0IF9faW1nSG92ZXJUaW1lciA9IDAsIF9faW1nSG92ZXJIaWRlVGltZXIgPSAwLCBfX2ltZ0hv
dmVyS2V5ID0gJyc7CiAgICBmdW5jdGlvbiBfX2ltZ0hvdmVyRW5zdXJlKCkgewogICAgICAgIGxldCBi
b3ggPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaW1nLWhvdmVyLXNpZGUnKTsKICAgICAgICBpZiAo
IWJveCkgewogICAgICAgICAgICBib3ggPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsgYm94
LmlkID0gJ2ltZy1ob3Zlci1zaWRlJzsKICAgICAgICAgICAgY29uc3QgZnJhbWUgPSBkb2N1bWVudC5j
cmVhdGVFbGVtZW50KCdkaXYnKTsgZnJhbWUuY2xhc3NOYW1lID0gJ2locC1mcmFtZSc7CiAgICAgICAg
ICAgIGNvbnN0IGltID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnaW1nJyk7IGltLmFsdCA9ICcnOwog
ICAgICAgICAgICBmcmFtZS5hcHBlbmRDaGlsZChpbSk7IGJveC5hcHBlbmRDaGlsZChmcmFtZSk7IGRv
Y3VtZW50LmJvZHkuYXBwZW5kQ2hpbGQoYm94KTsKICAgICAgICB9CiAgICAgICAgbGV0IHN0ID0gZG9j
dW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2ltZy1ob3Zlci1zaWRlLWNzcycpOwogICAgICAgIGlmICghc3Qp
IHsgc3QgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdzdHlsZScpOyBzdC5pZCA9ICdpbWctaG92ZXIt
c2lkZS1jc3MnOyBkb2N1bWVudC5oZWFkLmFwcGVuZENoaWxkKHN0KTsgfQogICAgICAgIHN0LnRleHRD
b250ZW50ID0gIiNpbWctaG92ZXItc2lkZXtwb3NpdGlvbjpmaXhlZDt6LWluZGV4OjEwMDAwMDtyaWdo
dDo2cHg7dG9wOjUwJTt0cmFuc2Zvcm06dHJhbnNsYXRlWSgtNTAlKTtwb2ludGVyLWV2ZW50czpub25l
O29wYWNpdHk6MDt2aXNpYmlsaXR5OmhpZGRlbjttYXgtd2lkdGg6bWluKDYyMHB4LDkydncpO21heC1o
ZWlnaHQ6bWluKDkydmgsOTIwcHgpfSNpbWctaG92ZXItc2lkZS5zaG93e29wYWNpdHk6MTt2aXNpYmls
aXR5OnZpc2libGV9I2ltZy1ob3Zlci1zaWRlIC5paHAtZnJhbWV7cGFkZGluZzozcHg7YmFja2dyb3Vu
ZDojZmZmO2JvcmRlcjoxcHggc29saWQgI0M1Q0REQztib3JkZXItcmFkaXVzOjJweDtib3gtc2hhZG93
OjAgNnB4IDE4cHggcmdiYSg0NCw0Niw1NCwuMTIpfSNpbWctaG92ZXItc2lkZSBpbWd7ZGlzcGxheTpi
bG9jazttYXgtd2lkdGg6bWluKDYxMnB4LDkwdncpO21heC1oZWlnaHQ6bWluKDkwdmgsOTAwcHgpO3dp
ZHRoOmF1dG87aGVpZ2h0OmF1dG87b2JqZWN0LWZpdDpjb250YWluO2JhY2tncm91bmQ6I2ZmZn0iOwog
ICAgICAgIHJldHVybiBib3g7CiAgICB9CiAgICB3aW5kb3cuX19pbWdIb3ZlclNob3cgPSBmdW5jdGlv
bihmaWxlLCBpZCkgewogICAgICAgIGNvbnN0IGJhcmUgPSBTdHJpbmcoZmlsZSB8fCAnJykuc3BsaXQo
L1tcXFxcL10vKS5wb3AoKTsgaWYgKCFiYXJlKSByZXR1cm47CiAgICAgICAgY29uc3QgYm94ID0gX19p
bWdIb3ZlckVuc3VyZSgpOyBjb25zdCBpbWcgPSBib3gucXVlcnlTZWxlY3RvcignaW1nJyk7IGlmICgh
aW1nKSByZXR1cm47CiAgICAgICAgYm94LmNsYXNzTGlzdC5hZGQoJ3Nob3cnKTsKICAgICAgICBpbWcu
b25lcnJvciA9ICgpID0+IHsKICAgICAgICAgICAgaW1nLm9uZXJyb3IgPSAoKSA9PiB7IGltZy5vbmVy
cm9yID0gbnVsbDsgdHJ5IHsgY29uc3QgYyA9IHRodW1iQ2FjaGUgJiYgdGh1bWJDYWNoZS5nZXQoU3Ry
aW5nKGlkKSk7IGlmIChjKSBpbWcuc3JjID0gYzsgfSBjYXRjaCAoZSkge30gfTsKICAgICAgICAgICAg
aW1nLnNyYyA9IFNUT1JFX0JBU0UgKyAndGhfJyArIGJhcmUucmVwbGFjZSgvXC5bXi5dKyQvLCAnJykg
KyAnLmpwZyc7CiAgICAgICAgfTsKICAgICAgICBpbWcub25sb2FkID0gKCkgPT4geyBpbWcub25lcnJv
ciA9IG51bGw7IH07CiAgICAgICAgaW1nLmRhdGFzZXQuYmFyZSA9IGJhcmU7IGltZy5zcmMgPSBTVE9S
RV9CQVNFICsgYmFyZTsKICAgIH07CiAgICB3aW5kb3cuX19pbWdIb3ZlckNsZWFyVWkgPSBmdW5jdGlv
bigpIHsKICAgICAgICBfX2ltZ0hvdmVyS2V5ID0gJyc7CiAgICAgICAgaWYgKF9faW1nSG92ZXJUaW1l
cikgeyBjbGVhclRpbWVvdXQoX19pbWdIb3ZlclRpbWVyKTsgX19pbWdIb3ZlclRpbWVyID0gMDsgfQog
ICAgICAgIGlmIChfX2ltZ0hvdmVySGlkZVRpbWVyKSB7IGNsZWFyVGltZW91dChfX2ltZ0hvdmVySGlk
ZVRpbWVyKTsgX19pbWdIb3ZlckhpZGVUaW1lciA9IDA7IH0KICAgICAgICBjb25zdCBib3ggPSBkb2N1
bWVudC5nZXRFbGVtZW50QnlJZCgnaW1nLWhvdmVyLXNpZGUnKTsgaWYgKGJveCkgYm94LmNsYXNzTGlz
dC5yZW1vdmUoJ3Nob3cnKTsKICAgICAgICBjb25zdCBpbWcgPSBib3ggJiYgYm94LnF1ZXJ5U2VsZWN0
b3IoJ2ltZycpOwogICAgICAgIGlmIChpbWcpIHsgaW1nLm9ubG9hZCA9IG51bGw7IGltZy5vbmVycm9y
ID0gbnVsbDsgaW1nLnJlbW92ZUF0dHJpYnV0ZSgnc3JjJyk7IGRlbGV0ZSBpbWcuZGF0YXNldC5iYXJl
OyB9CiAgICB9OwogICAgd2luZG93Ll9faW1nSG92ZXJIaWRlID0gZnVuY3Rpb24oKSB7IHdpbmRvdy5f
X2ltZ0hvdmVyQ2xlYXJVaSgpOyB9OwogICAgZnVuY3Rpb24gYmluZEltZ0hvdmVyUHJldmlldyhlbCwg
aWQsIGZpbGUpIHsKICAgICAgICBpZiAoIWVsKSByZXR1cm47CiAgICAgICAgY29uc3QgYmFyZSA9IFN0
cmluZyhmaWxlIHx8ICcnKS5zcGxpdCgvW1xcXFwvXS8pLnBvcCgpOyBpZiAoIWJhcmUpIHJldHVybjsK
ICAgICAgICBjb25zdCBrZXkgPSBTdHJpbmcoaWQpICsgJ3wnICsgYmFyZTsKICAgICAgICBlbC5zdHls
ZS5jdXJzb3IgPSAnem9vbS1pbic7CiAgICAgICAgZWwuYWRkRXZlbnRMaXN0ZW5lcignbW91c2VlbnRl
cicsICgpID0+IHsKICAgICAgICAgICAgaWYgKF9faW1nSG92ZXJIaWRlVGltZXIpIHsgY2xlYXJUaW1l
b3V0KF9faW1nSG92ZXJIaWRlVGltZXIpOyBfX2ltZ0hvdmVySGlkZVRpbWVyID0gMDsgfQogICAgICAg
ICAgICBfX2ltZ0hvdmVyS2V5ID0ga2V5OwogICAgICAgICAgICBpZiAoX19pbWdIb3ZlclRpbWVyKSBj
bGVhclRpbWVvdXQoX19pbWdIb3ZlclRpbWVyKTsKICAgICAgICAgICAgX19pbWdIb3ZlclRpbWVyID0g
c2V0VGltZW91dCgoKSA9PiB7IGlmIChfX2ltZ0hvdmVyS2V5ID09PSBrZXkpIHRyeSB7IHdpbmRvdy5f
X2ltZ0hvdmVyU2hvdyhiYXJlLCBpZCk7IH0gY2F0Y2ggKGUpIHt9IH0sIDYwKTsKICAgICAgICB9KTsK
ICAgICAgICBlbC5hZGRFdmVudExpc3RlbmVyKCdtb3VzZWxlYXZlJywgKCkgPT4gewogICAgICAgICAg
ICBpZiAoX19pbWdIb3ZlclRpbWVyKSB7IGNsZWFyVGltZW91dChfX2ltZ0hvdmVyVGltZXIpOyBfX2lt
Z0hvdmVyVGltZXIgPSAwOyB9CiAgICAgICAgICAgIF9faW1nSG92ZXJIaWRlVGltZXIgPSBzZXRUaW1l
b3V0KCgpID0+IHsgaWYgKCFfX2ltZ0hvdmVyS2V5IHx8IF9faW1nSG92ZXJLZXkgPT09IGtleSkgd2lu
ZG93Ll9faW1nSG92ZXJIaWRlKCk7IH0sIDcwKTsKICAgICAgICB9KTsKICAgIH0KICAgIGZ1bmN0aW9u
IGhhbmRsZUl0ZW1DbGljayhlLCBjKSB7CiAgICAgICAgaWYgKGUuc2hpZnRLZXkpIHsKICAgICAgICAg
ICAgZS5wcmV2ZW50RGVmYXVsdCgpOyBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICBjb25z
dCBsaXN0ID0gKHR5cGVvZiBuYXZMaXN0ID09PSAnZnVuY3Rpb24nID8gbmF2TGlzdCgpIDogdmlzaWJs
ZUxpc3QoKSk7CiAgICAgICAgICAgIGNvbnN0IGFuY2hvck9rID0gcmFuZ2VBbmNob3JDbGlja2VkICYm
IHJhbmdlQW5jaG9ySWQgJiYgbGlzdC5zb21lKHggPT4gK3guaWQgPT09ICtyYW5nZUFuY2hvcklkKTsK
ICAgICAgICAgICAgaWYgKCFhbmNob3JPaykgcmFuZ2VBbmNob3JJZCA9IHNlbGVjdGVkSWQgfHwgYy5p
ZDsKICAgICAgICAgICAgcmFuZ2VBbmNob3JDbGlja2VkID0gdHJ1ZTsKICAgICAgICAgICAgc2VsZWN0
UmFuZ2VUbyhjLmlkKTsKICAgICAgICAgICAgcmV0dXJuIHRydWU7CiAgICAgICAgfQogICAgICAgIGlm
IChlLmN0cmxLZXkgfHwgZS5tZXRhS2V5KSB7CiAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsg
ZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgdG9nZ2xlTXVsdGkoYy5pZCk7CiAgICAgICAg
ICAgIHJldHVybiB0cnVlOwogICAgICAgIH0KICAgICAgICByYW5nZUFuY2hvcklkID0gYy5pZDsKICAg
ICAgICByYW5nZUFuY2hvckNsaWNrZWQgPSB0cnVlOwogICAgICAgIHJldHVybiBmYWxzZTsKICAgIH0K
ICAgIGZ1bmN0aW9uIHRvZ2dsZU11bHRpKGlkKSB7CiAgICAgICAgaWQgPSAraWQ7CiAgICAgICAgY29u
c3QgaSA9IG11bHRpSWRzLmluZGV4T2YoaWQpOwogICAgICAgIGlmIChpID49IDApIG11bHRpSWRzLnNw
bGljZShpLCAxKTsKICAgICAgICBlbHNlIG11bHRpSWRzLnB1c2goaWQpOwogICAgICAgIHNlbGVjdGVk
SWQgPSBpZDsKICAgICAgICByYW5nZUFuY2hvcklkID0gaWQ7CiAgICAgICAgcmFuZ2VBbmNob3JDbGlj
a2VkID0gdHJ1ZTsKICAgICAgICB1cGRhdGVNdWx0aUJhZGdlKCk7CiAgICB9CgogICAgZnVuY3Rpb24g
cmVuZGVyKCkgewogICAgICAgIGhpZGVQYXRoVGlwKCk7CgogICAgICAgIGNvbnN0IHZpc2libGUgPSB2
aXNpYmxlTGlzdCgpOwogICAgICAgIGNvbnN0IGxvYWRlZCA9IGFsbENsaXBzLmxlbmd0aDsKICAgICAg
ICBjb25zdCBzaG93bkNvdW50ID0gdmlzaWJsZS5sZW5ndGg7CiAgICAgICAgLy8g5pS26JeP6KeS5qCH
77ya55SoIEFISyDkuIvlj5HnmoTmgLvmlbDvvIzpgb/lhY3jgIzlvZPliY3pobXph4zmlbDlh7rmnaXn
moTjgI3lkowgYmFyIOWvueS4jeS4igogICAgICAgIGxldCBwaW5uZWROID0gTnVtYmVyKHBpbm5lZFRv
dGFsKSB8fCAwOwogICAgICAgIGlmIChwaW5uZWROIDwgMSkgewogICAgICAgICAgICBpZiAoY3VyVGFi
ID09PSAncGlubmVkJykKICAgICAgICAgICAgICAgIHBpbm5lZE4gPSBNYXRoLm1heChOdW1iZXIoZGlz
a1RvdGFsKSB8fCAwLCBsb2FkZWQpOwogICAgICAgICAgICBlbHNlCiAgICAgICAgICAgICAgICBwaW5u
ZWROID0gYWxsQ2xpcHMuZmlsdGVyKGMgPT4gaXNQaW5uZWQoYykpLmxlbmd0aDsKICAgICAgICB9CiAg
ICAgICAgY29uc3QgcGluQ250ICA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwaW4tY250Jyk7CiAg
ICAgICAgcGluQ250LnRleHRDb250ZW50ICAgPSBwaW5uZWROOwogICAgICAgIHBpbkNudC5zdHlsZS5k
aXNwbGF5ID0gcGlubmVkTiA/ICcnIDogJ25vbmUnOwogICAgICAgIC8vIOaUtuiXjyB0YWLvvJpiYXIg
5LiO6KeS5qCH5ZCM5LiA5aWX5oC75pWw77yb5pyq5ruh6aG15pe25pi+56S6IOW3suWKoOi9vS/mgLvm
lbAKICAgICAgICBsZXQgc2hvd1RvdGFsID0gZGlza1RvdGFsID4gMCA/IGRpc2tUb3RhbCA6IChsb2Fk
ZWQgfHwgMCk7CiAgICAgICAgaWYgKGN1clRhYiA9PT0gJ3Bpbm5lZCcgJiYgcGlubmVkTiA+IHNob3dU
b3RhbCkKICAgICAgICAgICAgc2hvd1RvdGFsID0gcGlubmVkTjsKICAgICAgICBjb25zdCBxT24gPSBT
dHJpbmcocXVlcnkgfHwgJycpLnRyaW0oKS5sZW5ndGggPiAwOwogICAgICAgIGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCdiYXItdHh0JykudGV4dENvbnRlbnQgPSBxT24KICAgICAgICAgICAgPyAoc2hvd25D
b3VudCArICcg5p2hJykKICAgICAgICAgICAgOiAoc2hvd1RvdGFsID4gbG9hZGVkID8gKHNob3duQ291
bnQgKyAnIC8gJyArIHNob3dUb3RhbCArICcg5p2hJykgOiAoc2hvd1RvdGFsICsgJyDmnaEnKSk7CiAg
ICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2VtcHR5LXR4dCcpLnRleHRDb250ZW50ID0gRU1Q
VFlfTVNHW2N1clRhYl0gfHwgRU1QVFlfTVNHLmFsbDsKCiAgICAgICAgY29uc3QgaWRTZXQgPSBuZXcg
U2V0KGFsbENsaXBzLm1hcChjID0+ICtjLmlkKSk7CiAgICAgICAgbXVsdGlJZHMgPSBtdWx0aUlkcy5m
aWx0ZXIoaWQgPT4gaWRTZXQuaGFzKGlkKSk7CiAgICAgICAgdXBkYXRlTXVsdGlCYWRnZSgpOwoKICAg
ICAgICBjb25zdCBzaG93biA9IHZpc2libGU7CgogICAgICAgIGxpc3RFbC5xdWVyeVNlbGVjdG9yQWxs
KCcuaXRtLCAjbGlzdC1tb3JlJykuZm9yRWFjaChlID0+IGUucmVtb3ZlKCkpOwogICAgICAgIGlmIChi
b290TG9hZGluZykgewogICAgICAgICAgICBpZiAoc2tlbEVsKSBza2VsRWwuY2xhc3NMaXN0LmFkZCgn
b24nKTsKICAgICAgICAgICAgZW1wdHlFbC5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgICAg
ICB1cGRhdGVUb3BCdG4oKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICAvLyBX
YWl0aW5nIGZvciBmaXJzdCBkYXRhLCBvciBob3N0IG5ldmVyIGNvbmZpcm1lZCDigJRkb24ndCBmbGFz
aOOAjOaaguaXoOiusOW9leOAjQogICAgICAgIGlmICgod2FpdGluZ0RhdGEgfHwgIWhvc3RQdXNoZWRP
bmNlKSAmJiAhdmlzaWJsZS5sZW5ndGgpIHsKICAgICAgICAgICAgLy8gS2VlcCBza2VsZXRvbiBpZiBh
bHJlYWR5IG9uOyBuZXZlciBzdHJpcCBpdCB3aGlsZSB3YWl0aW5nCiAgICAgICAgICAgIGlmIChza2Vs
RWwgJiYgc2tlbEVsLmNsYXNzTGlzdC5jb250YWlucygnb24nKSkgewogICAgICAgICAgICAgICAgZW1w
dHlFbC5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgICAgICAgICAgdXBkYXRlVG9wQnRuKCk7
CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKHNrZWxF
bCkgc2tlbEVsLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgICAgIGNvbnN0IHFXYWl0ID0g
U3RyaW5nKHF1ZXJ5IHx8ICcnKS50cmltKCkubGVuZ3RoID4gMDsKICAgICAgICAgICAgaWYgKHFXYWl0
ICYmICFob3N0UHVzaGVkT25jZSkgewogICAgICAgICAgICAgICAgaWYgKHNrZWxFbCkgc2tlbEVsLmNs
YXNzTGlzdC5hZGQoJ29uJyk7CiAgICAgICAgICAgICAgICBlbXB0eUVsLmNsYXNzTGlzdC5yZW1vdmUo
J29uJyk7CiAgICAgICAgICAgICAgICB1cGRhdGVUb3BCdG4oKTsKICAgICAgICAgICAgICAgIHJldHVy
bjsKICAgICAgICAgICAgfQogICAgICAgICAgICBlbXB0eUVsLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7
CiAgICAgICAgICAgIHVwZGF0ZVRvcEJ0bigpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQog
ICAgICAgIGlmIChza2VsRWwpIHNrZWxFbC5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgIGlm
ICghdmlzaWJsZS5sZW5ndGgpIHsKICAgICAgICAgICAgLy8gTmV2ZXIgc2hvd+OAjOaaguaXoOiusOW9
leOAjXVudGlsIHdlIGhhdmUgc2VlbiBhIHJlYWwgbm9uLWVtcHR5IHB1c2gsCiAgICAgICAgICAgIC8v
IG9yIGEgY29uZmlybWVkIGVtcHR5IGFmdGVyIHdhcm0gKHNhd05vbkVtcHR5IGNhbiBiZSBzZXQgYnkg
ZW1wdHktZmFsbGJhY2spLgogICAgICAgICAgICAvLyBGaWx0ZXJlZCBzZWFyY2ggd2l0aCAwIGhpdHMg
aXMgYWxsb3dlZCBvbmNlIGhvc3QgcHVzaGVkLgogICAgICAgICAgICBjb25zdCBxT24gPSBTdHJpbmco
cXVlcnkgfHwgJycpLnRyaW0oKS5sZW5ndGggPiAwOwogICAgICAgICAgICBjb25zdCBhbGxvd0VtcHR5
ID0gaG9zdFB1c2hlZE9uY2UgJiYgc2F3Tm9uRW1wdHkgJiYgIXdhaXRpbmdEYXRhICYmICFib290TG9h
ZGluZwogICAgICAgICAgICAgICAgJiYgKHFPbiB8fCBkaXNrVG90YWwgPD0gMCk7CiAgICAgICAgICAg
IGlmICghYWxsb3dFbXB0eSkgewogICAgICAgICAgICAgICAgZW1wdHlFbC5jbGFzc0xpc3QucmVtb3Zl
KCdvbicpOwogICAgICAgICAgICAgICAgLy8gUHJlZmVyIHNrZWxldG9uIG92ZXIgYmxhbmsgd2hpbGUg
c3RpbGwgYm9vdHN0cmFwcGluZwogICAgICAgICAgICAgICAgaWYgKCFob3N0UHVzaGVkT25jZSB8fCB3
YWl0aW5nRGF0YSkgewogICAgICAgICAgICAgICAgICAgIGlmIChza2VsRWwpIHNrZWxFbC5jbGFzc0xp
c3QuYWRkKCdvbicpOwogICAgICAgICAgICAgICAgICAgIGNvbnN0IGFwcCA9IGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCdhcHAnKTsKICAgICAgICAgICAgICAgICAgICBpZiAoYXBwKSBhcHAuY2xhc3NMaXN0
LmFkZCgnYm9vdC1sb2FkaW5nJyk7CiAgICAgICAgICAgICAgICAgICAgYm9vdExvYWRpbmcgPSB0cnVl
OwogICAgICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgdXBkYXRlVG9wQnRuKCk7CiAgICAgICAg
ICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKHNlbGVjdEZpcnN0T25T
aG93KSB7CiAgICAgICAgICAgICAgICBzZWxlY3RGaXJzdE9uU2hvdyA9IGZhbHNlOwogICAgICAgICAg
ICAgICAgc2VsZWN0ZWRJZCA9IDA7CiAgICAgICAgICAgICAgICBjbGVhck11bHRpKCk7CiAgICAgICAg
ICAgICAgICBsaXN0RWwuc2Nyb2xsVG9wID0gMDsKICAgICAgICAgICAgfQogICAgICAgICAgICBlbXB0
eUVsLmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAgICAgICAgICAgIHVwZGF0ZVRvcEJ0bigpOwogICAgICAg
ICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGVtcHR5RWwuY2xhc3NMaXN0LnJlbW92ZSgnb24n
KTsKICAgICAgICBjb25zdCBmcmFnID0gZG9jdW1lbnQuY3JlYXRlRG9jdW1lbnRGcmFnbWVudCgpOwog
ICAgICAgIGNvbnN0IGJsb2NrcyA9IGJ1aWxkUGlubmVkQmxvY2tzKHNob3duKTsKICAgICAgICBsZXQg
bnVtID0gMDsKICAgICAgICBibG9ja3MuZm9yRWFjaChiID0+IHsKICAgICAgICAgICAgbnVtICs9IDE7
CiAgICAgICAgICAgIGlmIChiLmtpbmQgPT09ICdncm91cCcgJiYgYi5pdGVtcy5sZW5ndGggPiAxKQog
ICAgICAgICAgICAgICAgZnJhZy5hcHBlbmRDaGlsZChtYWtlR3JvdXBJdGVtKGIuaXRlbXMsIG51bSkp
OwogICAgICAgICAgICBlbHNlCiAgICAgICAgICAgICAgICBmcmFnLmFwcGVuZENoaWxkKG1ha2VJdGVt
KGIuaXRlbXNbMF0sIG51bSkpOwogICAgICAgIH0pOwogICAgICAgIGxpc3RFbC5hcHBlbmRDaGlsZChm
cmFnKTsKICAgICAgICB1cGRhdGVNb3JlRm9vdGVyKGRpc2tUb3RhbCk7CiAgICAgICAgaWYgKHNlbGVj
dEZpcnN0T25TaG93KSB7CiAgICAgICAgICAgIHNlbGVjdEZpcnN0T25TaG93ID0gZmFsc2U7CiAgICAg
ICAgICAgIHNlbGVjdGVkSWQgPSB2aXNpYmxlWzBdLmlkOwogICAgICAgICAgICBjbGVhck11bHRpKCk7
CiAgICAgICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSAwOwogICAgICAgIH0gZWxzZSBpZiAoIXZpc2li
bGUuc29tZShjID0+IGMuaWQgPT0gc2VsZWN0ZWRJZCkpIHsKICAgICAgICAgICAgc2VsZWN0ZWRJZCA9
IHZpc2libGVbMF0uaWQ7CiAgICAgICAgICAgIHJhbmdlQW5jaG9ySWQgPSBzZWxlY3RlZElkOwogICAg
ICAgICAgICByYW5nZUFuY2hvckNsaWNrZWQgPSBmYWxzZTsKICAgICAgICB9IGVsc2UgaWYgKCFyYW5n
ZUFuY2hvcklkKSB7CiAgICAgICAgICAgIHJhbmdlQW5jaG9ySWQgPSBzZWxlY3RlZElkOwogICAgICAg
IH0KICAgICAgICBzeW5jSXRlbUhpZ2hsaWdodCgpOwogICAgICAgIHVwZGF0ZVRvcEJ0bigpOwogICAg
ICAgIGlmICh3aW5kb3cuX19wZW5kaW5nSnVtcElkKSB7CiAgICAgICAgICAgIGNvbnN0IGppZCA9ICt3
aW5kb3cuX19wZW5kaW5nSnVtcElkOwogICAgICAgICAgICBjb25zdCBlbCA9IGxpc3RFbC5xdWVyeVNl
bGVjdG9yKCcubWctcm93W2RhdGEtaWQ9IicgKyBqaWQgKyAnIl0nKSB8fCBsaXN0RWwucXVlcnlTZWxl
Y3RvcignLml0bVtkYXRhLWlkPSInICsgamlkICsgJyJdJyk7CiAgICAgICAgICAgIGlmIChlbCkgewog
ICAgICAgICAgICAgICAgd2luZG93Ll9fcGVuZGluZ0p1bXBJZCA9IDA7CiAgICAgICAgICAgICAgICB3
aW5kb3cuX19qdW1wTG9hZFRyaWVzID0gMDsKICAgICAgICAgICAgICAgIHNlbGVjdGVkSWQgPSBqaWQ7
CiAgICAgICAgICAgICAgICByZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4gewogICAgICAgICAgICAg
ICAgICAgIGNvbnN0IG5vZGUgPSBsaXN0RWwucXVlcnlTZWxlY3RvcignLm1nLXJvd1tkYXRhLWlkPSIn
ICsgamlkICsgJyJdJykgfHwgbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5pdG1bZGF0YS1pZD0iJyArIGpp
ZCArICciXScpOwogICAgICAgICAgICAgICAgICAgIGlmICghbm9kZSkgcmV0dXJuOwogICAgICAgICAg
ICAgICAgICAgIG5vZGUuc2Nyb2xsSW50b1ZpZXcoeyBibG9jazogJ2NlbnRlcicgfSk7CiAgICAgICAg
ICAgICAgICAgICAgbm9kZS5jbGFzc0xpc3QuYWRkKCdqdW1wLWZsYXNoJyk7CiAgICAgICAgICAgICAg
ICAgICAgc2V0VGltZW91dCgoKSA9PiBub2RlLmNsYXNzTGlzdC5yZW1vdmUoJ2p1bXAtZmxhc2gnKSwg
OTAwKTsKICAgICAgICAgICAgICAgICAgICBzeW5jSXRlbUhpZ2hsaWdodCgpOwogICAgICAgICAgICAg
ICAgfSk7CiAgICAgICAgICAgIH0gZWxzZSBpZiAoYWxsQ2xpcHMubGVuZ3RoIDwgZGlza1RvdGFsICYm
ICh3aW5kb3cuX19qdW1wTG9hZFRyaWVzIHx8IDApIDwgNDApIHsKICAgICAgICAgICAgICAgIHdpbmRv
dy5fX2p1bXBMb2FkVHJpZXMgPSAod2luZG93Ll9fanVtcExvYWRUcmllcyB8fCAwKSArIDE7CiAgICAg
ICAgICAgICAgICByZXF1ZXN0TW9yZSgpOwogICAgICAgICAgICB9IGVsc2UgaWYgKGN1clRhYiAhPT0g
J2FsbCcgJiYgIXdpbmRvdy5fX2p1bXBGZWxsQmFjaykgewogICAgICAgICAgICAgICAgLy8gSXRlbSBn
b25lIGZyb20gdGhpcyB0YWIgKGUuZy4gdW5waW5uZWQpIOKAlCBmYWxsIGJhY2sgdG8g5YWo6YOoIG9u
Y2UKICAgICAgICAgICAgICAgIHdpbmRvdy5fX2p1bXBGZWxsQmFjayA9IHRydWU7CiAgICAgICAgICAg
ICAgICB3aW5kb3cuX19qdW1wTG9hZFRyaWVzID0gMDsKICAgICAgICAgICAgICAgIGN1clRhYiA9ICdh
bGwnOwogICAgICAgICAgICAgICAgbWFya1RhYignYWxsJyk7CiAgICAgICAgICAgICAgICByZXF1ZXN0
VmlldygpOwogICAgICAgICAgICB9IGVsc2UgewogICAgICAgICAgICAgICAgd2luZG93Ll9fcGVuZGlu
Z0p1bXBJZCA9IDA7CiAgICAgICAgICAgICAgICB3aW5kb3cuX19qdW1wTG9hZFRyaWVzID0gMDsKICAg
ICAgICAgICAgICAgIGlmIChhbGxDbGlwcy5zb21lKGMgPT4gK2MuaWQgPT09IGppZCkpCiAgICAgICAg
ICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IGppZDsKICAgICAgICAgICAgICAgIHN5bmNJdGVtSGlnaGxp
Z2h0KCk7CiAgICAgICAgICAgIH0KICAgICAgICB9CiAgICAgICAgcmVxdWVzdEFuaW1hdGlvbkZyYW1l
KCgpID0+IHsKICAgICAgICAgICAgaWYgKGFsbENsaXBzLmxlbmd0aCA8IGRpc2tUb3RhbAogICAgICAg
ICAgICAgICAgJiYgbGlzdEVsLnNjcm9sbEhlaWdodCA8PSBsaXN0RWwuY2xpZW50SGVpZ2h0ICsgMjAp
CiAgICAgICAgICAgICAgICByZXF1ZXN0TW9yZSgpOwogICAgICAgICAgICBzY2hlZHVsZUZpbGVHb25l
Q2hlY2soKTsKICAgICAgICB9KTsKICAgIH0KCiAgICBjb25zdCBTVkcgPSB7CiAgICAgICAgdGV4dDog
ICBgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9y
IiBzdHJva2Utd2lkdGg9IjIiPjxwYXRoIGQ9Ik00IDdWNGgxNnYzTTkgMjBoNk0xMiA0djE2Ii8+PC9z
dmc+YCwKICAgICAgICBtZDogICAgIGA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0iY3VycmVu
dENvbG9yIj48dGV4dCB4PSIxMiIgeT0iMTciIHRleHQtYW5jaG9yPSJtaWRkbGUiIGZvbnQtc2l6ZT0i
MTUiIGZvbnQtd2VpZ2h0PSI4MDAiIGZvbnQtZmFtaWx5PSJTZWdvZSBVSSxNaWNyb3NvZnQgWWFIZWks
c2Fucy1zZXJpZiI+TTwvdGV4dD48L3N2Zz5gLAogICAgICAgIGltYWdlOiAgYDxzdmcgdmlld0JveD0i
MCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIx
LjgiPjxyZWN0IHg9IjMiIHk9IjUiIHdpZHRoPSIxOCIgaGVpZ2h0PSIxNCIgcng9IjIiLz48Y2lyY2xl
IGN4PSI4LjUiIGN5PSIxMCIgcj0iMS41IiBmaWxsPSJjdXJyZW50Q29sb3IiIHN0cm9rZT0ibm9uZSIv
PjxwYXRoIGQ9Ik0zIDE2bDUtNSA0IDQgMy0zIDYgNiIvPjwvc3ZnPmAsCiAgICAgICAgdmlkZW86ICBg
PHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBz
dHJva2Utd2lkdGg9IjEuOCI+PHJlY3QgeD0iMyIgeT0iNiIgd2lkdGg9IjE0IiBoZWlnaHQ9IjEyIiBy
eD0iMiIvPjxwYXRoIGQ9Ik0xNyA5LjVsNC0yLjV2MTBsLTQtMi41VjkuNXoiIGZpbGw9ImN1cnJlbnRD
b2xvciIgc3Ryb2tlPSJub25lIi8+PHBhdGggZD0iTTguNSAxMC4ydjMuNmwzLjItMS44LTMuMi0xLjh6
IiBmaWxsPSJjdXJyZW50Q29sb3IiIHN0cm9rZT0ibm9uZSIvPjwvc3ZnPmAsCiAgICAgICAgZm9sZGVy
OiBgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9ImN1cnJlbnRDb2xvciI+PHBhdGggZD0iTTEw
IDRINGMtMS4xIDAtMiAuOS0yIDJ2MTJjMCAxLjEuOSAyIDIgMmgxNmMxLjEgMCAyLS45IDItMlY4YzAt
MS4xLS45LTItMi0yaC04bC0yLTJ6Ii8+PC9zdmc+YCwKICAgICAgICB6aXA6ICAgIGA8c3ZnIHZpZXdC
b3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0
aD0iMS44Ij48cGF0aCBkPSJNNiAzaDlsNSA1djEzYTEgMSAwIDAgMS0xIDFINmExIDEgMCAwIDEtMS0x
VjRhMSAxIDAgMCAxIDEtMXoiLz48cGF0aCBkPSJNMTQgM3Y2aDYiLz48L3N2Zz5gLAogICAgICAgIGFo
azogICAgYDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJjdXJyZW50Q29sb3IiPjx0ZXh0IHg9
IjEyIiB5PSIxNyIgdGV4dC1hbmNob3I9Im1pZGRsZSIgZm9udC1zaXplPSIxNCIgZm9udC13ZWlnaHQ9
IjcwMCI+SDwvdGV4dD48L3N2Zz5gLAogICAgICAgIGxuazogICAgYDxzdmcgdmlld0JveD0iMCAwIDI0
IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxw
YXRoIGQ9Ik0xMCAxM2E1IDUgMCAwIDAgNy4wNyAwbDIuMTItMi4xMmE1IDUgMCAwIDAtNy4wNy03LjA3
TDExIDUiLz48cGF0aCBkPSJNMTQgMTFhNSA1IDAgMCAwLTcuMDcgMEw0LjggMTMuMTJhNSA1IDAgMSAw
IDcuMDcgNy4wN0wxMyAxOSIvPjwvc3ZnPmAsCiAgICAgICAgZG9jOiAgICBgPHN2ZyB2aWV3Qm94PSIw
IDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEu
OCI+PHBhdGggZD0iTTcgM2g3bDUgNXYxM2ExIDEgMCAwIDEtMSAxSDdhMSAxIDAgMCAxLTEtMVY0YTEg
MSAwIDAgMSAxLTF6Ii8+PHBhdGggZD0iTTE0IDN2Nmg2Ii8+PC9zdmc+YCwKICAgICAgICBtdWx0aTog
IGA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3Ii
IHN0cm9rZS13aWR0aD0iMS44Ij48cmVjdCB4PSI3IiB5PSI3IiB3aWR0aD0iMTIiIGhlaWdodD0iMTQi
IHJ4PSIxLjUiLz48cGF0aCBkPSJNNSAxN1Y1YTEgMSAwIDAgMSAxLTFoMTAiLz48L3N2Zz5gCiAgICB9
OwoKICAgIGZ1bmN0aW9uIGZpbGVFeHQocGF0aCkgewogICAgICAgIGNvbnN0IGJhc2UgPSBTdHJpbmco
cGF0aCB8fCAnJykuc3BsaXQoL1tcXC9dLykucG9wKCkgfHwgJyc7CiAgICAgICAgY29uc3QgaSA9IGJh
c2UubGFzdEluZGV4T2YoJy4nKTsKICAgICAgICByZXR1cm4gaSA+IDAgPyBiYXNlLnNsaWNlKGkgKyAx
KS50b0xvd2VyQ2FzZSgpIDogJyc7CiAgICB9CiAgICBjb25zdCBpc0ltYWdlRXh0ID0gZSA9PiBbJ3Bu
ZycsJ2pwZycsJ2pwZWcnLCdnaWYnLCd3ZWJwJywnYm1wJywnaWNvJywndGlmJywndGlmZicsJ3N2Zydd
LmluY2x1ZGVzKGUpOwogICAgY29uc3QgaXNWaWRlb0V4dCA9IGUgPT4gWydtcDQnLCdta3YnLCdhdmkn
LCdtb3YnLCd3bXYnLCdmbHYnLCd3ZWJtJywnbTR2JywnbXBlZycsJ21wZycsJ3RzJywnbTJ0cycsJzNn
cCcsJ3JtJywncm12YiddLmluY2x1ZGVzKGUpOwogICAgY29uc3QgaXNaaXBFeHQgICA9IGUgPT4gWyd6
aXAnLCdyYXInLCc3eicsJ3RhcicsJ2d6JywnYnoyJ10uaW5jbHVkZXMoZSk7CgogICAgZnVuY3Rpb24g
aWNvbkZvckZpbGVzKGZpbGVzKSB7CiAgICAgICAgaWYgKCFmaWxlcy5sZW5ndGgpICAgIHJldHVybiB7
IGNsczogJ2ZpbGUgZnQtZG9jJywgc3ZnOiBTVkcuZG9jIH07CiAgICAgICAgaWYgKGZpbGVzLmxlbmd0
aCA+IDEpIHJldHVybiB7IGNsczogJ2ZpbGUgZnQtbG5rJywgc3ZnOiBTVkcubXVsdGkgfTsKICAgICAg
ICBjb25zdCBleHQgPSBmaWxlRXh0KGZpbGVzWzBdKTsKICAgICAgICBpZiAoIWV4dCkgICAgICAgICAg
ICAgIHJldHVybiB7IGNsczogJ2ZpbGUgZnQtZGlyJywgc3ZnOiBTVkcuZm9sZGVyIH07CiAgICAgICAg
aWYgKGlzSW1hZ2VFeHQoZXh0KSkgICByZXR1cm4geyBjbHM6ICdmaWxlIGZ0LWltZycsIHN2ZzogU1ZH
LmltYWdlIH07CiAgICAgICAgaWYgKGlzVmlkZW9FeHQoZXh0KSkgICByZXR1cm4geyBjbHM6ICdmaWxl
IGZ0LXZpZCcsIHN2ZzogKFNWRy52aWRlbyB8fCBTVkcuZG9jKSB9OwogICAgICAgIGlmIChpc1ppcEV4
dChleHQpKSAgICAgcmV0dXJuIHsgY2xzOiAnZmlsZSBmdC16aXAnLCBzdmc6IFNWRy56aXAgfTsKICAg
ICAgICBpZiAoZXh0ID09PSAnYWhrJykgICAgIHJldHVybiB7IGNsczogJ2ZpbGUgZnQtYWhrJywgc3Zn
OiBTVkcuYWhrIH07CiAgICAgICAgaWYgKGV4dCA9PT0gJ2xuaycpICAgICByZXR1cm4geyBjbHM6ICdm
aWxlIGZ0LWxuaycsIHN2ZzogU1ZHLmxuayB9OwogICAgICAgIHJldHVybiB7IGNsczogJ2ZpbGUgZnQt
ZG9jJywgc3ZnOiBTVkcuZG9jIH07CiAgICB9CgogICAgZnVuY3Rpb24gc3JjV2luTGFiZWwoYykgewog
ICAgICAgIGNvbnN0IHQgPSBTdHJpbmcoYyAmJiBjLnNyY1RpdGxlIHx8ICcnKS50cmltKCk7CiAgICAg
ICAgaWYgKHQpIHJldHVybiB0OwogICAgICAgIHJldHVybiBTdHJpbmcoYyAmJiBjLnNyY0V4ZSB8fCAn
JykucmVwbGFjZSgvXC5leGUkL2ksICcnKTsKICAgIH0KICAgIGZ1bmN0aW9uIHNyY1RpdGxlSHRtbChj
KSB7CiAgICAgICAgLy8g5YiX6KGo5Lit6Ze0L+WPs+S+p+S4jeWGjeaYvuekuueql+WPo+agh+mimO+8
jOadpea6kOWPquS/neeVmeWPs+S+p+Wbvuagh+aCrOWBnOaPkOekugogICAgICAgIHJldHVybiAnJzsK
ICAgIH0KICAgIGZ1bmN0aW9uIGV4cGFuZENoZXZyb24ob3BlbikgewogICAgICAgIHJldHVybiBvcGVu
CiAgICAgICAgICAgID8gYDxzdmcgdmlld0JveD0iMCAwIDE2IDE2IiB3aWR0aD0iMTQiIGhlaWdodD0i
MTQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCIgc3Ry
b2tlLWxpbmVjYXA9InJvdW5kIj48cG9seWxpbmUgcG9pbnRzPSI0IDEwIDggNiAxMiAxMCIvPjwvc3Zn
PjxzcGFuPuaUtui1tzwvc3Bhbj5gCiAgICAgICAgICAgIDogYDxzdmcgdmlld0JveD0iMCAwIDE2IDE2
IiB3aWR0aD0iMTQiIGhlaWdodD0iMTQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBz
dHJva2Utd2lkdGg9IjEuOCIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIj48cG9seWxpbmUgcG9pbnRzPSI0
IDYgOCAxMCAxMiA2Ii8+PC9zdmc+PHNwYW4+5bGV5byAPC9zcGFuPmA7CiAgICB9CiAgICBmdW5jdGlv
biBsaXN0RXhwYW5kTWF4UHgoKSB7CiAgICAgICAgY29uc3QgaCA9IChsaXN0RWwgJiYgbGlzdEVsLmNs
aWVudEhlaWdodCkgfHwgMzYwOwogICAgICAgIC8vIOWHoOS5juWNoOa7oeWIl+ihqO+8jOW6lemDqOeV
mee6puS4gOihjAogICAgICAgIHJldHVybiBNYXRoLm1heCg5NiwgaCAtIDI4KTsKICAgIH0KICAgIGZ1
bmN0aW9uIGFwcGx5RXhwYW5kZWRQcmV2aWV3KHByZXYsIGZ1bGxUZXh0KSB7CiAgICAgICAgY29uc3Qg
bWF4SCA9IGxpc3RFeHBhbmRNYXhQeCgpOwogICAgICAgIHByZXYuc3R5bGUubWF4SGVpZ2h0ID0gbWF4
SCArICdweCc7CiAgICAgICAgcHJldi5jbGFzc0xpc3QuYWRkKCdleHBhbmRlZCcpOwogICAgICAgIHNl
dEhsVGV4dChwcmV2LCBmdWxsVGV4dCk7CiAgICAgICAgLy8g5LuN5rqi5Ye677ya5oiq5pat5bm25Zyo
5pyr5bC+5Yqg44CMIC4uLuOAjQogICAgICAgIGlmIChwcmV2LnNjcm9sbEhlaWdodCA8PSBwcmV2LmNs
aWVudEhlaWdodCArIDIpCiAgICAgICAgICAgIHJldHVybjsKICAgICAgICBsZXQgbG8gPSAwLCBoaSA9
IGZ1bGxUZXh0Lmxlbmd0aCwgYmVzdCA9IDA7CiAgICAgICAgd2hpbGUgKGxvIDw9IGhpKSB7CiAgICAg
ICAgICAgIGNvbnN0IG1pZCA9IChsbyArIGhpKSA+PiAxOwogICAgICAgICAgICBzZXRIbFRleHQocHJl
diwgZnVsbFRleHQuc2xpY2UoMCwgbWlkKSArICcgLi4uJyk7CiAgICAgICAgICAgIGlmIChwcmV2LnNj
cm9sbEhlaWdodCA8PSBwcmV2LmNsaWVudEhlaWdodCArIDIpIHsKICAgICAgICAgICAgICAgIGJlc3Qg
PSBtaWQ7CiAgICAgICAgICAgICAgICBsbyA9IG1pZCArIDE7CiAgICAgICAgICAgIH0gZWxzZSB7CiAg
ICAgICAgICAgICAgICBoaSA9IG1pZCAtIDE7CiAgICAgICAgICAgIH0KICAgICAgICB9CiAgICAgICAg
c2V0SGxUZXh0KHByZXYsIGZ1bGxUZXh0LnNsaWNlKDAsIGJlc3QpICsgJyAuLi4nKTsKICAgIH0KICAg
IGZ1bmN0aW9uIGNvbGxhcHNlUHJldmlldyhwcmV2LCBmdWxsVGV4dCkgewogICAgICAgIHByZXYuY2xh
c3NMaXN0LnJlbW92ZSgnZXhwYW5kZWQnKTsKICAgICAgICBwcmV2LnN0eWxlLm1heEhlaWdodCA9ICcn
OwogICAgICAgIHNldEhsVGV4dChwcmV2LCBmdWxsVGV4dCk7CiAgICB9CgogICAgZnVuY3Rpb24gZmF2
R3JvdXBPZihjKSB7CiAgICAgICAgcmV0dXJuIFN0cmluZyhjICYmIGMuZmF2R3JvdXAgfHwgJycpLnRy
aW0oKTsKICAgIH0KICAgIGZ1bmN0aW9uIGNsaXBDb250ZW50UHJldmlldyhjKSB7CiAgICAgICAgY29u
c3QgdHlwZSA9IG5vcm1UeXBlKGMudHlwZSk7CiAgICAgICAgaWYgKHR5cGUgPT09ICdpbWFnZScpIHJl
dHVybiAnW+WbvuWDj10nICsgKGMud2lkdGggJiYgYy5oZWlnaHQgPyAoJyAnICsgYy53aWR0aCArICfD
lycgKyBjLmhlaWdodCkgOiAnJyk7CiAgICAgICAgaWYgKHR5cGUgPT09ICdmaWxlJykgewogICAgICAg
ICAgICBjb25zdCBmaWxlcyA9IFN0cmluZyhjLnByZXZpZXcgfHwgYy5kYXRhIHx8ICcnKS5zcGxpdCgv
XHI/XG4vKS5maWx0ZXIoQm9vbGVhbik7CiAgICAgICAgICAgIHJldHVybiBmaWxlcy5tYXAoZiA9PiBm
LnNwbGl0KC9bXFwvXS8pLnBvcCgpKS5qb2luKCcgwrcgJykgfHwgJ1vmlofku7ZdJzsKICAgICAgICB9
CiAgICAgICAgbGV0IF9wID0gU3RyaW5nKGMucHJldmlldyB8fCBjLmRhdGEgfHwgJycpOwogICAgICAg
IHsgY29uc3QgX24gPSBOdW1iZXIoYy5jaGFyQ291bnQpIHx8IDA7IGlmIChfbiA+IF9wLmxlbmd0aCAm
JiBfcC5sZW5ndGgpIF9wICs9ICcuLi4nOyB9CiAgICAgICAgcmV0dXJuIF9wOwogICAgfQogICAgZnVu
Y3Rpb24gYnVpbGRQaW5uZWRCbG9ja3MobGlzdCkgewogICAgICAgIGNvbnN0IHVzZWQgPSBuZXcgU2V0
KCk7CiAgICAgICAgY29uc3Qgb3V0ID0gW107CiAgICAgICAgZm9yIChjb25zdCBjIG9mIGxpc3QpIHsK
ICAgICAgICAgICAgaWYgKHVzZWQuaGFzKCtjLmlkKSkgY29udGludWU7CiAgICAgICAgICAgIGNvbnN0
IGdpZCA9IGZhdkdyb3VwT2YoYyk7CiAgICAgICAgICAgIGlmICghZ2lkKSB7CiAgICAgICAgICAgICAg
ICB1c2VkLmFkZCgrYy5pZCk7CiAgICAgICAgICAgICAgICBvdXQucHVzaCh7IGtpbmQ6ICdzaW5nbGUn
LCBpdGVtczogW2NdIH0pOwogICAgICAgICAgICAgICAgY29udGludWU7CiAgICAgICAgICAgIH0KICAg
ICAgICAgICAgY29uc3QgbWVtYmVycyA9IGxpc3QuZmlsdGVyKHggPT4gZmF2R3JvdXBPZih4KSA9PT0g
Z2lkKTsKICAgICAgICAgICAgbWVtYmVycy5mb3JFYWNoKG0gPT4gdXNlZC5hZGQoK20uaWQpKTsKICAg
ICAgICAgICAgaWYgKG1lbWJlcnMubGVuZ3RoIDwgMikKICAgICAgICAgICAgICAgIG91dC5wdXNoKHsg
a2luZDogJ3NpbmdsZScsIGl0ZW1zOiBbbWVtYmVyc1swXSB8fCBjXSB9KTsKICAgICAgICAgICAgZWxz
ZQogICAgICAgICAgICAgICAgb3V0LnB1c2goeyBraW5kOiAnZ3JvdXAnLCBnaWQsIGl0ZW1zOiBtZW1i
ZXJzIH0pOwogICAgICAgIH0KICAgICAgICByZXR1cm4gb3V0OwogICAgfQogICAgZnVuY3Rpb24gX19w
cmVwUGFzdGUoKSB7CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgY29uc3QgcyA9IGRvY3VtZW50Lmdl
dEVsZW1lbnRCeUlkKCdzZWFyY2gnKTsKICAgICAgICAgICAgaWYgKHMgJiYgZG9jdW1lbnQuYWN0aXZl
RWxlbWVudCA9PT0gcykgdHJ5IHsgcy5ibHVyKCk7IH0gY2F0Y2gge30KICAgICAgICAgICAgaWYgKHdp
bmRvdy5nZXRTZWxlY3Rpb24pIHdpbmRvdy5nZXRTZWxlY3Rpb24oKS5yZW1vdmVBbGxSYW5nZXMoKTsK
ICAgICAgICB9IGNhdGNoIHt9CiAgICB9CiAgICBmdW5jdGlvbiBwYXN0ZU9uZShjKSB7CiAgICAgICAg
X19wcmVwUGFzdGUoKTsKICAgICAgICBzZWxlY3RlZElkID0gYy5pZDsKICAgICAgICBpZiAobXVsdGlJ
ZHMubGVuZ3RoKSBjbGVhck11bHRpKCk7CiAgICAgICAgc3luY0l0ZW1IaWdobGlnaHQoKTsKICAgICAg
ICBtYXJrUGFzdGVkTG9jYWwoYy5pZCk7CiAgICAgICAgYWhrKCdwYXN0ZScsIFN0cmluZyhjLmlkKSk7
CiAgICB9CiAgICBmdW5jdGlvbiBpc0l0ZW1DaHJvbWVUYXJnZXQodCkgewogICAgICAgIHJldHVybiAh
ISh0ICYmIHQuY2xvc2VzdCAmJiB0LmNsb3Nlc3QoJy5pLWV4cGFuZC1idG4sIC5pLXNyYy1pY28sIC5t
Zy1zcmMsIC5mZC1idG4sIC5mZC1wYXRoLCBidXR0b24sIGEsIGlucHV0JykpOwogICAgfQogICAgZnVu
Y3Rpb24gYmVnaW5QYXN0ZUZyb21JdGVtKGUsIGMpIHsKICAgICAgICBpZiAoZS5idXR0b24gIT0gbnVs
bCAmJiBlLmJ1dHRvbiAhPT0gMCkgcmV0dXJuOwogICAgICAgIGlmIChpc0l0ZW1DaHJvbWVUYXJnZXQo
ZS50YXJnZXQpKSByZXR1cm47CiAgICAgICAgaWYgKGhhbmRsZUl0ZW1DbGljayhlLCBjKSkKICAgICAg
ICAgICAgcmV0dXJuOwogICAgICAgIF9fcHJlcFBhc3RlKCk7CiAgICAgICAgc2VsZWN0ZWRJZCA9IGMu
aWQ7CiAgICAgICAgcmFuZ2VBbmNob3JJZCA9IGMuaWQ7CiAgICAgICAgaWYgKG11bHRpSWRzLmxlbmd0
aCA+IDAgJiYgbXVsdGlJZHMuaW5jbHVkZXMoK2MuaWQpKSB7CiAgICAgICAgICAgIGNvbnN0IGlkcyA9
IG11bHRpSWRzLnNsaWNlKCk7CiAgICAgICAgICAgIGNsZWFyTXVsdGkoKTsKICAgICAgICAgICAgbWFy
a1Bhc3RlZExvY2FsKGlkcyk7CiAgICAgICAgICAgIGlmIChpZHMubGVuZ3RoID4gMSkgYWhrKCdwYXN0
ZU1hbnknLCBpZHMuam9pbignLCcpKTsKICAgICAgICAgICAgZWxzZSBhaGsoJ3Bhc3RlJywgU3RyaW5n
KGlkc1swXSkpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGlmIChtdWx0aUlk
cy5sZW5ndGgpIGNsZWFyTXVsdGkoKTsKICAgICAgICBzeW5jSXRlbUhpZ2hsaWdodCgpOwogICAgICAg
IG1hcmtQYXN0ZWRMb2NhbChjLmlkKTsKICAgICAgICBhaGsoJ3Bhc3RlJywgU3RyaW5nKGMuaWQpKTsK
ICAgIH0KICAgIGZ1bmN0aW9uIG1ha2VHcm91cEl0ZW0oaXRlbXMsIGlkeCkgewogICAgICAgIGNvbnN0
IGVsID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgZWwuY2xhc3NOYW1lID0g
J2l0bSBpdC1ncm91cCcKICAgICAgICAgICAgKyAoaXRlbXMuc29tZShjID0+ICtjLmlkID09PSArc2Vs
ZWN0ZWRJZCkgPyAnIHNlbCcgOiAnJykKICAgICAgICAgICAgKyAoaXRlbXMuc29tZShjID0+IG11bHRp
SWRzLmluY2x1ZGVzKCtjLmlkKSkgPyAnIG11bHRpJyA6ICcnKTsKICAgICAgICBlbC5kYXRhc2V0Lmdy
b3VwID0gZmF2R3JvdXBPZihpdGVtc1swXSkgfHwgJyc7CiAgICAgICAgZWwuZGF0YXNldC5pZCA9IGl0
ZW1zWzBdLmlkOwoKICAgICAgICBjb25zdCBoZWFkID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2
Jyk7CiAgICAgICAgaGVhZC5jbGFzc05hbWUgPSAnbWctaGVhZCc7CiAgICAgICAgaGVhZC5pbm5lckhU
TUwgPSAnPHNwYW4gY2xhc3M9Im1nLXRhZyI+5ZCI5bm2PC9zcGFuPjxzcGFuPicgKyBpdGVtcy5sZW5n
dGggKyAnIOadoSDCtyDngrnlh7vljZXmnaHnspjotLQ8L3NwYW4+JzsKICAgICAgICBlbC5hcHBlbmRD
aGlsZChoZWFkKTsKCiAgICAgICAgaXRlbXMuZm9yRWFjaChjID0+IHsKICAgICAgICAgICAgY29uc3Qg
cm93ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIHJvdy5jbGFzc05h
bWUgPSAnbWctcm93JwogICAgICAgICAgICAgICAgKyAoK3NlbGVjdGVkSWQgPT09ICtjLmlkID8gJyBz
ZWwnIDogJycpCiAgICAgICAgICAgICAgICArIChtdWx0aUlkcy5pbmNsdWRlcygrYy5pZCkgPyAnIG11
bHRpJyA6ICcnKTsKICAgICAgICAgICAgcm93LmRhdGFzZXQuaWQgPSBjLmlkOwoKICAgICAgICAgICAg
Y29uc3QgdG9wID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIHRvcC5j
bGFzc05hbWUgPSAnbWctcm93LXRvcCc7CiAgICAgICAgICAgIGNvbnN0IG1haW4gPSBkb2N1bWVudC5j
cmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgbWFpbi5jbGFzc05hbWUgPSAnbWctcm93LW1h
aW4nOwoKICAgICAgICAgICAgY29uc3QgdGl0bGUgPSBTdHJpbmcoYy5mYXZUaXRsZSB8fCAnJykudHJp
bSgpOwogICAgICAgICAgICBpZiAodGl0bGUpIHsKICAgICAgICAgICAgICAgIGNvbnN0IHQgPSBkb2N1
bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgICAgIHQuY2xhc3NOYW1lID0gJ21n
LXRpdGxlJzsKICAgICAgICAgICAgICAgIHNldEhsVGV4dCh0LCB0aXRsZSk7CiAgICAgICAgICAgICAg
ICBtYWluLmFwcGVuZENoaWxkKHQpOwogICAgICAgICAgICB9CiAgICAgICAgICAgIGNvbnN0IGJvZHkg
PSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgYm9keS5jbGFzc05hbWUg
PSAnbWctYm9keScgKyAobm9ybVR5cGUoYy50eXBlKSA9PT0gJ2ltYWdlJyA/ICcgaW1nJyA6ICcnKTsK
ICAgICAgICAgICAgc2V0SGxUZXh0KGJvZHksIGNsaXBDb250ZW50UHJldmlldyhjKSk7CiAgICAgICAg
ICAgIG1haW4uYXBwZW5kQ2hpbGQoYm9keSk7CiAgICAgICAgICAgIHRvcC5hcHBlbmRDaGlsZChtYWlu
KTsKCiAgICAgICAgICAgIGNvbnN0IHNyY0ljbyA9IFN0cmluZyhjLnNyY0ljb24gfHwgJycpOwogICAg
ICAgICAgICBjb25zdCBzcmNFeGUgPSBTdHJpbmcoYy5zcmNFeGUgfHwgJycpOwogICAgICAgICAgICBj
b25zdCBzcmNUaXRsZSA9IFN0cmluZyhjLnNyY1RpdGxlIHx8ICcnKTsKICAgICAgICAgICAgaWYgKHNy
Y0ljbykgewogICAgICAgICAgICAgICAgY29uc3QgaW1nID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgn
aW1nJyk7CiAgICAgICAgICAgICAgICBpbWcuY2xhc3NOYW1lID0gJ21nLXNyYyc7CiAgICAgICAgICAg
ICAgICBpbWcuc3JjID0gU1RPUkVfQkFTRSArIGVuY29kZVVSSUNvbXBvbmVudChzcmNJY28pOwogICAg
ICAgICAgICAgICAgaW1nLmFsdCA9ICcnOwogICAgICAgICAgICAgICAgY29uc3QgdGlwVHh0ID0gc3Jj
VGl0bGUgfHwgc3JjRXhlIHx8ICfmnaXmupAnOwogICAgICAgICAgICAgICAgaW1nLnRpdGxlID0gdGlw
VHh0OwogICAgICAgICAgICAgICAgaW1nLm9uY2xpY2sgPSBlID0+IHsgZS5wcmV2ZW50RGVmYXVsdCgp
OyBlLnN0b3BQcm9wYWdhdGlvbigpOyBzaG93U3JjVGlwKGltZywgdGlwVHh0KTsgfTsKICAgICAgICAg
ICAgICAgIHRvcC5hcHBlbmRDaGlsZChpbWcpOwogICAgICAgICAgICB9CiAgICAgICAgICAgIHJvdy5h
cHBlbmRDaGlsZCh0b3ApOwoKICAgICAgICAgICAgcm93Lm9ucG9pbnRlcmRvd24gPSBlID0+IHsKICAg
ICAgICAgICAgICAgIGlmIChlLmJ1dHRvbiAhPT0gMCkgcmV0dXJuOwogICAgICAgICAgICAgICAgZS5z
dG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgIGJlZ2luUGFzdGVGcm9tSXRlbShlLCBjKTsK
ICAgICAgICAgICAgfTsKICAgICAgICAgICAgcm93Lm9uY29udGV4dG1lbnUgPSBlID0+IHsKICAgICAg
ICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0
aW9uKCk7CiAgICAgICAgICAgICAgICBzZWxlY3RlZElkID0gYy5pZDsKICAgICAgICAgICAgICAgIHNo
b3dDdHgoZS5jbGllbnRYLCBlLmNsaWVudFksIGMpOwogICAgICAgICAgICB9OwogICAgICAgICAgICBl
bC5hcHBlbmRDaGlsZChyb3cpOwogICAgICAgIH0pOwoKICAgICAgICBlbC5vbmNvbnRleHRtZW51ID0g
ZSA9PiB7CiAgICAgICAgICAgIGlmIChlLnRhcmdldC5jbG9zZXN0KCcubWctcm93JykpIHJldHVybjsK
ICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICBzZWxlY3RlZElkID0gaXRl
bXNbMF0uaWQ7CiAgICAgICAgICAgIHNob3dDdHgoZS5jbGllbnRYLCBlLmNsaWVudFksIGl0ZW1zWzBd
KTsKICAgICAgICB9OwogICAgICAgIHJldHVybiBlbDsKICAgIH0KCiAgICBmdW5jdGlvbiBtYWtlSXRl
bShjLCBpZHgpIHsKICAgICAgICBjb25zdCB0eXBlICAgPSBub3JtVHlwZShjLnR5cGUpOwogICAgICAg
IGNvbnN0IHBpbm5lZCA9IGlzUGlubmVkKGMpOwogICAgICAgIGNvbnN0IHBhc3RlZCA9IGlzUGFzdGVk
KGMpOwogICAgICAgIGNvbnN0IGVsICAgICA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwog
ICAgICAgIGVsLmNsYXNzTmFtZSAgPSAnaXRtJwogICAgICAgICAgICArIChzZWxlY3RlZElkID09IGMu
aWQgPyAnIHNlbCcgOiAnJykKICAgICAgICAgICAgKyAobXVsdGlJZHMuaW5jbHVkZXMoK2MuaWQpID8g
JyBtdWx0aScgOiAnJyk7CiAgICAgICAgZWwuZGF0YXNldC5pZCA9IGMuaWQ7CgogICAgICAgIGNvbnN0
IGljbyAgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICBjb25zdCBib2R5ID0g
ZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgYm9keS5jbGFzc05hbWUgPSAnaS1i
b2R5JzsKCiAgICAgICAgaWYgKHR5cGUgPT09ICdpbWFnZScpIHsKICAgICAgICAgICAgaWNvLmNsYXNz
TmFtZSA9ICdpLWljbyBpbWFnZSc7CiAgICAgICAgICAgIGljby5pbm5lckhUTUwgPSBTVkcuaW1hZ2U7
CiAgICAgICAgICAgIGJpbmRJbWdIb3ZlclByZXZpZXcoaWNvLCBjLmlkLCBjLmltZ0ZpbGUpOwogICAg
ICAgICAgICBjb25zdCB3cmFwID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAg
ICAgIHdyYXAuY2xhc3NOYW1lID0gJ2ktdGh1bWItd3JhcCc7CiAgICAgICAgICAgIGNvbnN0IGltZyAg
PSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdpbWcnKTsKICAgICAgICAgICAgaW1nLmNsYXNzTmFtZSA9
ICdpLXRodW1iJzsKICAgICAgICAgICAgaW1nLmFsdCA9ICcnOwogICAgICAgICAgICBjb25zdCBmaWxl
ID0gU3RyaW5nKGMuaW1nRmlsZSB8fCAnJyk7CiAgICAgICAgICAgIGxldCBmYWxsYmFjayA9IFN0cmlu
ZyhjLmRhdGEgfHwgJycpOwogICAgICAgICAgICAvLyBOZXZlciBzeW5jLWNhbGwgQUhLIHRodW1iIGhl
cmUg4oCUIGZyZWV6ZXMgdGFiIHN3aXRjaGVzOyBQdXNoU3RvcmVUaHVtYnMgZmlsbHMgYXN5bmMKICAg
ICAgICAgICAgaWYgKCFmYWxsYmFjay5zdGFydHNXaXRoKCdkYXRhOicpICYmIHRodW1iQ2FjaGUuaGFz
KFN0cmluZyhjLmlkKSkpCiAgICAgICAgICAgICAgICBmYWxsYmFjayA9IFN0cmluZyh0aHVtYkNhY2hl
LmdldChTdHJpbmcoYy5pZCkpKTsKICAgICAgICAgICAgaW1nLm9ubG9hZCA9ICgpID0+IHsKICAgICAg
ICAgICAgICAgIGNvbnN0IG13ID0gd3JhcC5jbGllbnRXaWR0aCB8fCAzMDA7CiAgICAgICAgICAgICAg
ICBjb25zdCBudyA9IGltZy5uYXR1cmFsV2lkdGggIHx8IDA7CiAgICAgICAgICAgICAgICBjb25zdCBu
aCA9IGltZy5uYXR1cmFsSGVpZ2h0IHx8IDA7CiAgICAgICAgICAgICAgICBpZiAoIW53IHx8ICFuaCkg
cmV0dXJuOwogICAgICAgICAgICAgICAgY29uc3Qgc2NhbGUgPSBNYXRoLm1pbigxLCAxODAgLyBuaCwg
bXcgLyBudyk7CiAgICAgICAgICAgICAgICBpbWcuc3R5bGUud2lkdGggID0gTWF0aC5yb3VuZChudyAq
IHNjYWxlKSArICdweCc7CiAgICAgICAgICAgICAgICBpbWcuc3R5bGUuaGVpZ2h0ID0gTWF0aC5yb3Vu
ZChuaCAqIHNjYWxlKSArICdweCc7CiAgICAgICAgICAgIH07CiAgICAgICAgICAgIGJpbmRTdG9yZVRo
dW1iKGltZywgZmlsZSwgYy5pZCwgZmFsbGJhY2spOwogICAgICAgICAgICB3cmFwLmFwcGVuZENoaWxk
KGltZyk7CiAgICAgICAgICAgIGNvbnN0IG1ldGEgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYn
KTsKICAgICAgICAgICAgbWV0YS5jbGFzc05hbWUgPSAnaS1tZXRhJzsKICAgICAgICAgICAgbWV0YS5p
bm5lckhUTUwgID0gYDxzcGFuIGNsYXNzPSJpLXRpbWUiPiR7YWdvKGMudGltZSl9PC9zcGFuPiR7bWV0
YUNlbnRlckh0bWwoZmFsc2UpfTxkaXYgY2xhc3M9ImktbWV0YS1yaWdodCI+JHtjLndpZHRoID8gYDxz
cGFuIGNsYXNzPSJpLXRhZyI+JHtjLndpZHRofcOXJHtjLmhlaWdodH0gcHg8L3NwYW4+YCA6ICcnfTwv
ZGl2PmA7CiAgICAgICAgICAgIGJvZHkuYXBwZW5kQ2hpbGQod3JhcCk7CiAgICAgICAgICAgIGJvZHku
YXBwZW5kQ2hpbGQobWV0YSk7CiAgICAgICAgfSBlbHNlIGlmICh0eXBlID09PSAnZmlsZScpIHsKICAg
ICAgICAgICAgY29uc3QgZmlsZXMgPSBTdHJpbmcoYy5wcmV2aWV3IHx8IGMuZGF0YSB8fCAnJykuc3Bs
aXQoL1xyP1xuLykuZmlsdGVyKEJvb2xlYW4pOwogICAgICAgICAgICBjb25zdCBpbWFnZVBhdGhzID0g
ZmlsZXMuZmlsdGVyKGYgPT4gaXNJbWFnZUV4dChmaWxlRXh0KGYpKSk7CiAgICAgICAgICAgIGNvbnN0
IGljICAgID0gaWNvbkZvckZpbGVzKGZpbGVzKTsKICAgICAgICAgICAgaWNvLmNsYXNzTmFtZSA9ICdp
LWljbyAnICsgaWMuY2xzOwogICAgICAgICAgICBpY28uaW5uZXJIVE1MID0gaWMuc3ZnOwoKICAgICAg
ICAgICAgbGV0IHRodW1iRmlsZSA9IFN0cmluZyhjLmltZ0ZpbGUgfHwgJycpOwogICAgICAgICAgICAv
KiBlbnN1cmVGaWxlSW1nIGRlZmVycmVkOiBhdm9pZCBzeW5jIGZyZWV6ZSBvbiBmaWxlIHRhYiAqLwoK
ICAgICAgICAgICAgLy8gSW1hZ2UtZm9ybWF0IGZpbGVzOiBzYW1lIHRodW1ibmFpbCBydWxlcyBhcyBz
Y3JlZW5zaG90IGNsaXBzCiAgICAgICAgICAgIGlmICh0aHVtYkZpbGUgfHwgaW1hZ2VQYXRocy5sZW5n
dGgpIHsKICAgICAgICAgICAgICAgIGNvbnN0IHdyYXAgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdk
aXYnKTsKICAgICAgICAgICAgICAgIHdyYXAuY2xhc3NOYW1lID0gJ2ktdGh1bWItd3JhcCc7CiAgICAg
ICAgICAgICAgICBjb25zdCBpbWcgID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnaW1nJyk7CiAgICAg
ICAgICAgICAgICBpbWcuY2xhc3NOYW1lID0gJ2ktdGh1bWInOwogICAgICAgICAgICAgICAgaW1nLmFs
dCA9ICcnOwogICAgICAgICAgICAgICAgaW1nLm9ubG9hZCA9ICgpID0+IHsKICAgICAgICAgICAgICAg
ICAgICBjb25zdCBtdyA9IHdyYXAuY2xpZW50V2lkdGggfHwgMzAwOwogICAgICAgICAgICAgICAgICAg
IGNvbnN0IG53ID0gaW1nLm5hdHVyYWxXaWR0aCAgfHwgMDsKICAgICAgICAgICAgICAgICAgICBjb25z
dCBuaCA9IGltZy5uYXR1cmFsSGVpZ2h0IHx8IDA7CiAgICAgICAgICAgICAgICAgICAgaWYgKCFudyB8
fCAhbmgpIHJldHVybjsKICAgICAgICAgICAgICAgICAgICBjb25zdCBzY2FsZSA9IE1hdGgubWluKDEs
IDE4MCAvIG5oLCBtdyAvIG53KTsKICAgICAgICAgICAgICAgICAgICBpbWcuc3R5bGUud2lkdGggID0g
TWF0aC5yb3VuZChudyAqIHNjYWxlKSArICdweCc7CiAgICAgICAgICAgICAgICAgICAgaW1nLnN0eWxl
LmhlaWdodCA9IE1hdGgucm91bmQobmggKiBzY2FsZSkgKyAncHgnOwogICAgICAgICAgICAgICAgfTsK
ICAgICAgICAgICAgLyogZW5zdXJlRmlsZUltZyBkZWZlcnJlZDogYXZvaWQgc3luYyBmcmVlemUgb24g
ZmlsZSB0YWIgKi8KICAgICAgICAgICAgICAgIGJpbmRTdG9yZVRodW1iKGltZywgdGh1bWJGaWxlLCBj
LmlkLCAnJyk7CiAgICAgICAgICAgICAgICB3cmFwLmFwcGVuZENoaWxkKGltZyk7CiAgICAgICAgICAg
ICAgICBib2R5LmFwcGVuZENoaWxkKHdyYXApOwogICAgICAgICAgICB9CgogICAgICAgICAgICBjb25z
dCBuYW1lID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIG5hbWUuY2xh
c3NOYW1lICA9ICdpLW5hbWUnOwogICAgICAgICAgICBzZXRIbFRleHQobmFtZSwgZmlsZXMubWFwKGYg
PT4gZi5zcGxpdCgvW1xcL10vKS5wb3AoKSkuam9pbignXG4nKSB8fCAnKOaWh+S7tiknKTsKCiAgICAg
ICAgICAgIGVsLl9maWxlUGF0aHMgPSBmaWxlczsKCiAgICAgICAgICAgIGNvbnN0IGRldGFpbCA9IGRv
Y3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBkZXRhaWwuY2xhc3NOYW1lID0g
J2ktZmlsZS1kZXRhaWwnOwoKICAgICAgICAgICAgY29uc3QgbWV0YSA9IGRvY3VtZW50LmNyZWF0ZUVs
ZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBtZXRhLmNsYXNzTmFtZSA9ICdpLW1ldGEnOwogICAgICAg
ICAgICBsZXQgcmlnaHQgPSAnJzsKICAgICAgICAgICAgcmlnaHQgKz0gYDxzcGFuIGNsYXNzPSJpLXRh
ZyI+JHtjLmZpbGVDb3VudCB8fCBmaWxlcy5sZW5ndGggfHwgMX0g5Liq5paH5Lu2PC9zcGFuPmA7CiAg
ICAgICAgICAgIGlmICgodGh1bWJGaWxlIHx8IGltYWdlUGF0aHMubGVuZ3RoKSAmJiBjLndpZHRoKQog
ICAgICAgICAgICAgICAgcmlnaHQgKz0gYDxzcGFuIGNsYXNzPSJpLXRhZyI+JHtjLndpZHRofcOXJHtj
LmhlaWdodH0gcHg8L3NwYW4+YDsKICAgICAgICAgICAgY29uc3QgZXhwYW5kSHRtbCA9IGV4cGFuZENo
ZXZyb24oZmFsc2UpOwogICAgICAgICAgICBjb25zdCBjb2xsYXBzZUh0bWwgPSBleHBhbmRDaGV2cm9u
KHRydWUpOwogICAgICAgICAgICBtZXRhLmlubmVySFRNTCA9CiAgICAgICAgICAgICAgICBgPHNwYW4g
Y2xhc3M9ImktdGltZSI+JHthZ28oYy50aW1lKX08L3NwYW4+YCArCiAgICAgICAgICAgICAgICBtZXRh
Q2VudGVySHRtbCh7IG9uOiB0cnVlLCBodG1sOiBleHBhbmRIdG1sIH0pICsKICAgICAgICAgICAgICAg
IGA8ZGl2IGNsYXNzPSJpLW1ldGEtcmlnaHQiPiR7cmlnaHR9PC9kaXY+YDsKCiAgICAgICAgICAgIGNv
bnN0IGV4cEJ0biA9IG1ldGEucXVlcnlTZWxlY3RvcignLmktZXhwYW5kLWJ0bicpOwogICAgICAgICAg
ICBsZXQgZGV0YWlsQnVpbHQgPSBmYWxzZTsKICAgICAgICAgICAgZXhwQnRuLm9uY2xpY2sgPSBlID0+
IHsKICAgICAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgICAgIGUuc3Rv
cFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgICAgICBjb25zdCBvcGVuID0gIWRldGFpbC5jbGFzc0xp
c3QuY29udGFpbnMoJ29uJyk7CiAgICAgICAgICAgICAgICBpZiAob3BlbiAmJiAhZGV0YWlsQnVpbHQp
IHsKICAgICAgICAgICAgICAgICAgICBjb25zdCBwYXRoUm93cyA9IGVsLl9wYXRoUm93cyB8fCBjaGVj
a0ZpbGVQYXRocyhlbC5fZmlsZVBhdGhzIHx8IGZpbGVzKTsKICAgICAgICAgICAgICAgICAgICBmaWxs
RmlsZURldGFpbFBhbmVsKGRldGFpbCwgcGF0aFJvd3MpOwogICAgICAgICAgICAgICAgICAgIGRldGFp
bEJ1aWx0ID0gdHJ1ZTsKICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgIGRldGFpbC5jbGFz
c0xpc3QudG9nZ2xlKCdvbicsIG9wZW4pOwogICAgICAgICAgICAgICAgaWYgKG9wZW4pIHsKICAgICAg
ICAgICAgICAgICAgICBkZXRhaWwuc3R5bGUubWF4SGVpZ2h0ID0gbGlzdEV4cGFuZE1heFB4KCkgKyAn
cHgnOwogICAgICAgICAgICAgICAgICAgIGRldGFpbC5zdHlsZS5vdmVyZmxvdyA9ICdhdXRvJzsKICAg
ICAgICAgICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgICAgICAgICAgZGV0YWlsLnN0eWxlLm1heEhl
aWdodCA9ICcnOwogICAgICAgICAgICAgICAgICAgIGRldGFpbC5zdHlsZS5vdmVyZmxvdyA9ICcnOwog
ICAgICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgZXhwQnRuLmlubmVySFRNTCA9IG9wZW4gPyBj
b2xsYXBzZUh0bWwgOiBleHBhbmRIdG1sOwogICAgICAgICAgICB9OwoKICAgICAgICAgICAgYm9keS5h
cHBlbmRDaGlsZChuYW1lKTsKICAgICAgICAgICAgYm9keS5hcHBlbmRDaGlsZChkZXRhaWwpOwogICAg
ICAgICAgICBib2R5LmFwcGVuZENoaWxkKG1ldGEpOwogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAg
IGNvbnN0IHVzZU0gPSBjbGlwVXNlc01JY29uKGMpOwogICAgICAgICAgICBpY28uY2xhc3NOYW1lID0g
dXNlTSA/ICdpLWljbyBtZCcgOiAnaS1pY28gdGV4dCc7CiAgICAgICAgICAgIGljby5pbm5lckhUTUwg
PSB1c2VNID8gKFNWRy5tZCB8fCBTVkcudGV4dCkgOiBTVkcudGV4dDsKICAgICAgICAgICAgLyogcGxh
aW4tbGlzdC1wcmV2ICovCiAgICAgICAgICAgIC8qIHByZXZpZXctZWxsaXBzaXMgKi8KICAgICAgICAg
ICAgbGV0IHR4dCAgPSBjLnByZXZpZXcgfHwgYy5kYXRhIHx8ICcnOwogICAgICAgICAgICB7IGNvbnN0
IF9uID0gTnVtYmVyKGMuY2hhckNvdW50KSB8fCAwOyBpZiAoX24gPiB0eHQubGVuZ3RoICYmIHR4dC5s
ZW5ndGgpIHR4dCArPSAnLi4uJzsgfQogICAgICAgICAgICBjb25zdCBwcmV2ID0gZG9jdW1lbnQuY3Jl
YXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIHByZXYuY2xhc3NOYW1lICA9ICdpLXByZXYnICsg
KGlzVXJsKHR4dCkgPyAnIHVybCcgOiAnJyk7CiAgICAgICAgICAgIHNldEhsVGV4dChwcmV2LCB0eHQp
OwoKICAgICAgICAgICAgY29uc3QgbWV0YSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwog
ICAgICAgICAgICBtZXRhLmNsYXNzTmFtZSA9ICdpLW1ldGEnOwoKICAgICAgICAgICAgY29uc3QgY2hh
cnMgPSBOdW1iZXIoYy5jaGFyQ291bnQpIHx8IDA7CiAgICAgICAgICAgIGNvbnN0IHJpZ2h0SFRNTCA9
IGA8c3BhbiBjbGFzcz0iaS1jaGFycyI+PHNwYW4gY2xhc3M9Im4iPiR7Y2hhcnN9PC9zcGFuPiDlrZfn
rKY8L3NwYW4+YDsKCiAgICAgICAgICAgIG1ldGEuaW5uZXJIVE1MID0KICAgICAgICAgICAgICAgIGA8
c3BhbiBjbGFzcz0iaS10aW1lIj4ke2FnbyhjLnRpbWUpfTwvc3Bhbj5gICsKICAgICAgICAgICAgICAg
IG1ldGFDZW50ZXJIdG1sKHsKICAgICAgICAgICAgICAgICAgICBvbjogZmFsc2UsCiAgICAgICAgICAg
ICAgICAgICAgaHRtbDogZXhwYW5kQ2hldnJvbihmYWxzZSkKICAgICAgICAgICAgICAgIH0pICsKICAg
ICAgICAgICAgICAgIGA8ZGl2IGNsYXNzPSJpLW1ldGEtcmlnaHQgdGV4dC1tZXRhIj4ke3JpZ2h0SFRN
TH08L2Rpdj5gOwoKICAgICAgICAgICAgYm9keS5hcHBlbmRDaGlsZChwcmV2KTsKICAgICAgICAgICAg
Ym9keS5hcHBlbmRDaGlsZChtZXRhKTsKCiAgICAgICAgICAgIGNvbnN0IGV4cEJ0biA9IG1ldGEucXVl
cnlTZWxlY3RvcignLmktZXhwYW5kLWJ0bicpOwogICAgICAgICAgICBpZiAoZXhwQnRuKSB7CiAgICAg
ICAgICAgICAgICBleHBCdG4ub25jbGljayA9IGUgPT4gewogICAgICAgICAgICAgICAgICAgIGUuc3Rv
cFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgICAgICAgICAgY29uc3Qgd2lsbEV4cGFuZCA9ICFwcmV2
LmNsYXNzTGlzdC5jb250YWlucygnZXhwYW5kZWQnKTsKICAgICAgICAgICAgICAgICAgICBpZiAod2ls
bEV4cGFuZCkgewogICAgICAgICAgICAgICAgICAgICAgICBhcHBseUV4cGFuZGVkUHJldmlldyhwcmV2
LCB0eHQpOwogICAgICAgICAgICAgICAgICAgICAgICBleHBCdG4uaW5uZXJIVE1MID0gZXhwYW5kQ2hl
dnJvbih0cnVlKTsKICAgICAgICAgICAgICAgICAgICAgICAgdHJ5IHsgZWwuc2Nyb2xsSW50b1ZpZXco
eyBibG9jazogJ25lYXJlc3QnIH0pOyB9IGNhdGNoIHt9CiAgICAgICAgICAgICAgICAgICAgfSBlbHNl
IHsKICAgICAgICAgICAgICAgICAgICAgICAgY29sbGFwc2VQcmV2aWV3KHByZXYsIHR4dCk7CiAgICAg
ICAgICAgICAgICAgICAgICAgIGV4cEJ0bi5pbm5lckhUTUwgPSBleHBhbmRDaGV2cm9uKGZhbHNlKTsK
ICAgICAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICB9OwogICAgICAgICAgICAgICAgY29u
c3QgY2hlY2tPdmVyZmxvdyA9ICgpID0+IHsKICAgICAgICAgICAgICAgICAgICBjb25zdCBwbGFpbkxl
biA9IFN0cmluZyhjLnByZXZpZXcgfHwgYy5kYXRhIHx8ICcnKS5sZW5ndGg7CiAgICAgICAgICAgICAg
ICAgICAgY29uc3QgZnVsbE4gPSBOdW1iZXIoYy5jaGFyQ291bnQpIHx8IDA7CiAgICAgICAgICAgICAg
ICAgICAgY29uc3QgdHJ1bmMgPSBmdWxsTiA+IHBsYWluTGVuOwogICAgICAgICAgICAgICAgICAgIGlm
IChwcmV2LnNjcm9sbEhlaWdodCA+IHByZXYuY2xpZW50SGVpZ2h0ICsgMiB8fCB0cnVuYykKICAgICAg
ICAgICAgICAgICAgICAgICAgZXhwQnRuLmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAgICAgICAgICAgICAg
ICAgICAgZWxzZQogICAgICAgICAgICAgICAgICAgICAgICBleHBCdG4uY2xhc3NMaXN0LnJlbW92ZSgn
b24nKTsKICAgICAgICAgICAgICAgIH07CiAgICAgICAgICAgICAgICByZXF1ZXN0QW5pbWF0aW9uRnJh
bWUoY2hlY2tPdmVyZmxvdyk7CiAgICAgICAgICAgICAgICBzZXRUaW1lb3V0KGNoZWNrT3ZlcmZsb3cs
IDgwKTsKICAgICAgICAgICAgfQogICAgICAgIH0KCiAgICAgICAgY29uc3QgZmF2VCA9IFN0cmluZyhj
LmZhdlRpdGxlIHx8ICcnKS50cmltKCk7CiAgICAgICAgaWYgKGZhdlQpIHsKICAgICAgICAgICAgY29u
c3QgZnQgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgZnQuY2xhc3NO
YW1lID0gJ2ktZmF2LXRpdGxlJzsKICAgICAgICAgICAgc2V0SGxUZXh0KGZ0LCBmYXZUKTsKICAgICAg
ICAgICAgYm9keS5pbnNlcnRCZWZvcmUoZnQsIGJvZHkuZmlyc3RDaGlsZCk7CiAgICAgICAgfQoKICAg
ICAgICBpZiAocGFzdGVkKSB7CiAgICAgICAgICAgIGNvbnN0IGJhZGdlID0gZG9jdW1lbnQuY3JlYXRl
RWxlbWVudCgnc3BhbicpOwogICAgICAgICAgICBiYWRnZS5jbGFzc05hbWUgPSAnaS11c2VkJzsKICAg
ICAgICAgICAgYmFkZ2UudGl0bGUgPSAn5bey57KY6LS0JzsKICAgICAgICAgICAgYmFkZ2UuaW5uZXJI
VE1MID0gYDxzdmcgdmlld0JveD0iMCAwIDE2IDE2IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRD
b2xvciIgc3Ryb2tlLXdpZHRoPSIyLjQiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVq
b2luPSJyb3VuZCI+PHBvbHlsaW5lIHBvaW50cz0iMy41IDguNSA2LjUgMTEuNSAxMi41IDQuNSIvPjwv
c3ZnPmA7CiAgICAgICAgICAgIGljby5hcHBlbmRDaGlsZChiYWRnZSk7CiAgICAgICAgfQoKICAgICAg
ICBjb25zdCBudW0gPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICBudW0uY2xh
c3NOYW1lID0gJ2ktbnVtJzsKICAgICAgICBjb25zdCBudW1UeHQgPSBkb2N1bWVudC5jcmVhdGVFbGVt
ZW50KCdzcGFuJyk7CiAgICAgICAgbnVtVHh0LnRleHRDb250ZW50ID0gaWR4OwogICAgICAgIG51bS5h
cHBlbmRDaGlsZChudW1UeHQpOwogICAgICAgIGNvbnN0IHNyY0ljbyA9IFN0cmluZyhjLnNyY0ljb24g
fHwgJycpOwogICAgICAgIGNvbnN0IHNyY0V4ZSA9IFN0cmluZyhjLnNyY0V4ZSB8fCAnJyk7CiAgICAg
ICAgY29uc3Qgc3JjVGl0bGUgPSBTdHJpbmcoYy5zcmNUaXRsZSB8fCAnJyk7CiAgICAgICAgaWYgKHNy
Y0ljbykgewogICAgICAgICAgICBjb25zdCBpbWcgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdpbWcn
KTsKICAgICAgICAgICAgaW1nLmNsYXNzTmFtZSA9ICdpLXNyYy1pY28nOwogICAgICAgICAgICBpbWcu
c3JjID0gU1RPUkVfQkFTRSArIGVuY29kZVVSSUNvbXBvbmVudChzcmNJY28pOwogICAgICAgICAgICBp
bWcuYWx0ID0gJyc7CiAgICAgICAgICAgIGNvbnN0IHRpcFR4dCA9IHNyY1RpdGxlIHx8IHNyY0V4ZSB8
fCAn5p2l5rqQJzsKICAgICAgICAgICAgaW1nLnRpdGxlID0gdGlwVHh0OwogICAgICAgICAgICBpbWcu
b25jbGljayA9IGUgPT4geyBlLnByZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0aW9uKCk7IHNo
b3dTcmNUaXAoaW1nLCB0aXBUeHQpOyB9OwogICAgICAgICAgICBudW0uYXBwZW5kQ2hpbGQoaW1nKTsK
ICAgICAgICB9CgogICAgICAgIGVsLmFwcGVuZENoaWxkKGljbyk7CiAgICAgICAgZWwuYXBwZW5kQ2hp
bGQoYm9keSk7CiAgICAgICAgZWwuYXBwZW5kQ2hpbGQobnVtKTsKCiAgICAgICAgZWwub25wb2ludGVy
ZG93biA9IGUgPT4gewogICAgICAgICAgICBiZWdpblBhc3RlRnJvbUl0ZW0oZSwgYyk7CiAgICAgICAg
fTsKICAgICAgICBlbC5vbmNvbnRleHRtZW51ID0gZSA9PiB7CiAgICAgICAgICAgIGUucHJldmVudERl
ZmF1bHQoKTsKICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IGMuaWQ7CiAgICAgICAgICAgIHNob3dDdHgo
ZS5jbGllbnRYLCBlLmNsaWVudFksIGMpOwogICAgICAgIH07CgogICAgICAgIHJldHVybiBlbDsKICAg
IH0KCiAgICBjb25zdCBwYXRoVGlwRWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncGF0aC10aXAn
KTsKICAgIGxldCBwYXRoVGlwVGltZXIgPSAwOwogICAgbGV0IHBhdGhUaXBIaWRlVGltZXIgPSAwOwog
ICAgbGV0IHBhdGhUaXBUb2tlbiA9IDA7CiAgICBsZXQgcGF0aFRpcEFuY2hvckJ0biA9IG51bGw7Cgog
ICAgZnVuY3Rpb24gaGlkZVBhdGhUaXAoKSB7CiAgICAgICAgY2xlYXJUaW1lb3V0KHBhdGhUaXBUaW1l
cik7CiAgICAgICAgY2xlYXJUaW1lb3V0KHBhdGhUaXBIaWRlVGltZXIpOwogICAgICAgIHBhdGhUaXBU
b2tlbisrOwogICAgICAgIGlmIChwYXRoVGlwQW5jaG9yQnRuKSB7CiAgICAgICAgICAgIHBhdGhUaXBB
bmNob3JCdG4uY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICAgICAgcGF0aFRpcEFuY2hvckJ0
biA9IG51bGw7CiAgICAgICAgfQogICAgICAgIGlmIChwYXRoVGlwRWwpIHsKICAgICAgICAgICAgcGF0
aFRpcEVsLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgICAgIHBhdGhUaXBFbC5zZXRBdHRy
aWJ1dGUoJ2FyaWEtaGlkZGVuJywgJ3RydWUnKTsKICAgICAgICB9CiAgICB9CiAgICBmdW5jdGlvbiBw
bGFjZVBhdGhUaXAoYW5jaG9yRWwpIHsKICAgICAgICBpZiAoIXBhdGhUaXBFbCB8fCAhYW5jaG9yRWwp
IHJldHVybjsKICAgICAgICBjb25zdCB0aXAgPSBwYXRoVGlwRWw7CiAgICAgICAgY29uc3QgYXIgPSBh
bmNob3JFbC5nZXRCb3VuZGluZ0NsaWVudFJlY3QoKTsKICAgICAgICBjb25zdCBwYWQgPSA4OwogICAg
ICAgIHRpcC5zdHlsZS5sZWZ0ID0gJzBweCc7CiAgICAgICAgdGlwLnN0eWxlLnRvcCA9ICcwcHgnOwog
ICAgICAgIHRpcC5jbGFzc0xpc3QuYWRkKCdvbicpOwogICAgICAgIGNvbnN0IHR3ID0gdGlwLm9mZnNl
dFdpZHRoOwogICAgICAgIGNvbnN0IHRoID0gdGlwLm9mZnNldEhlaWdodDsKICAgICAgICBsZXQgbGVm
dCA9IGFyLmxlZnQ7CiAgICAgICAgbGV0IHRvcCA9IGFyLmJvdHRvbSArIDY7CiAgICAgICAgaWYgKGxl
ZnQgKyB0dyA+IHdpbmRvdy5pbm5lcldpZHRoIC0gcGFkKQogICAgICAgICAgICBsZWZ0ID0gTWF0aC5t
YXgocGFkLCB3aW5kb3cuaW5uZXJXaWR0aCAtIHR3IC0gcGFkKTsKICAgICAgICBpZiAobGVmdCA8IHBh
ZCkgbGVmdCA9IHBhZDsKICAgICAgICBpZiAodG9wICsgdGggPiB3aW5kb3cuaW5uZXJIZWlnaHQgLSBw
YWQpCiAgICAgICAgICAgIHRvcCA9IE1hdGgubWF4KHBhZCwgYXIudG9wIC0gdGggLSA2KTsKICAgICAg
ICB0aXAuc3R5bGUubGVmdCA9IGxlZnQgKyAncHgnOwogICAgICAgIHRpcC5zdHlsZS50b3AgPSB0b3Ag
KyAncHgnOwogICAgfQogICAgICAgIGZ1bmN0aW9uIGNoZWNrRmlsZVBhdGhzKHBhdGhzKSB7CiAgICAg
ICAgY29uc3QgbGlzdCA9IChwYXRocyB8fCBbXSkubWFwKHAgPT4gewogICAgICAgICAgICBsZXQgcGF0
aCA9IFN0cmluZyhwIHx8ICcnKS50cmltKCk7CiAgICAgICAgICAgIGlmICgocGF0aC5zdGFydHNXaXRo
KCciJykgJiYgcGF0aC5lbmRzV2l0aCgnIicpKSB8fCAocGF0aC5zdGFydHNXaXRoKCInIikgJiYgcGF0
aC5lbmRzV2l0aCgiJyIpKSkKICAgICAgICAgICAgICAgIHBhdGggPSBwYXRoLnNsaWNlKDEsIC0xKS50
cmltKCk7CiAgICAgICAgICAgIHJldHVybiBwYXRoOwogICAgICAgIH0pOwogICAgICAgIC8vIE9uZSBo
b3N0IHJvdW5kLXRyaXAgZm9yIHRoZSB3aG9sZSBsaXN0IOKAlCBOw5cgcGF0aEV4aXN0cyBmcmVlemVz
IGZpbGUgdGFiCiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgY29uc3QgcmF3ID0gYWhrUmV0KCdjaGVj
a1BhdGhzJywgbGlzdC5qb2luKCdcbicpKTsKICAgICAgICAgICAgaWYgKHJhdykgewogICAgICAgICAg
ICAgICAgY29uc3QgcGFyc2VkID0gdHlwZW9mIHJhdyA9PT0gJ3N0cmluZycgPyBKU09OLnBhcnNlKHJh
dykgOiByYXc7CiAgICAgICAgICAgICAgICBpZiAoQXJyYXkuaXNBcnJheShwYXJzZWQpICYmIHBhcnNl
ZC5sZW5ndGgpIHsKICAgICAgICAgICAgICAgICAgICByZXR1cm4gbGlzdC5tYXAoKHBhdGgsIGkpID0+
IHsKICAgICAgICAgICAgICAgICAgICAgICAgY29uc3Qgcm93ID0gcGFyc2VkW2ldIHx8IHt9OwogICAg
ICAgICAgICAgICAgICAgICAgICByZXR1cm4gewogICAgICAgICAgICAgICAgICAgICAgICAgICAgcGF0
aDogcGF0aCB8fCBTdHJpbmcocm93LnBhdGggfHwgJycpLAogICAgICAgICAgICAgICAgICAgICAgICAg
ICAgZXhpc3RzOiByb3cuZXhpc3RzID09PSB0cnVlIHx8IHJvdy5leGlzdHMgPT09IDEgfHwgcm93LmV4
aXN0cyA9PT0gJzEnLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgaXNEaXI6ICEhKHJvdy5pc0Rp
ciA9PT0gdHJ1ZSB8fCByb3cuaXNEaXIgPT09IDEgfHwgcm93LmlzRGlyID09PSAnMScpCiAgICAgICAg
ICAgICAgICAgICAgICAgIH07CiAgICAgICAgICAgICAgICAgICAgfSk7CiAgICAgICAgICAgICAgICB9
CiAgICAgICAgICAgIH0KICAgICAgICB9IGNhdGNoIHt9CiAgICAgICAgcmV0dXJuIGxpc3QubWFwKHBh
dGggPT4gewogICAgICAgICAgICBpZiAoIXBhdGgpIHJldHVybiB7IHBhdGgsIGV4aXN0czogZmFsc2Us
IGlzRGlyOiBmYWxzZSB9OwogICAgICAgICAgICBsZXQgZXhpc3RzID0gZmFsc2U7CiAgICAgICAgICAg
IHRyeSB7CiAgICAgICAgICAgICAgICBjb25zdCBmbGFnID0gU3RyaW5nKGFoa1JldCgncGF0aEV4aXN0
cycsIHBhdGgpID8/ICcnKS50cmltKCkudG9Mb3dlckNhc2UoKTsKICAgICAgICAgICAgICAgIGV4aXN0
cyA9IChmbGFnID09PSAnMScgfHwgZmxhZyA9PT0gJ3RydWUnKTsKICAgICAgICAgICAgfSBjYXRjaCB7
fQogICAgICAgICAgICByZXR1cm4geyBwYXRoLCBleGlzdHMsIGlzRGlyOiBmYWxzZSB9OwogICAgICAg
IH0pOwogICAgfQogICAgbGV0IGdvbmVDaGVja1RpbWVyID0gMDsKICAgIGZ1bmN0aW9uIHNjaGVkdWxl
RmlsZUdvbmVDaGVjaygpIHsKICAgICAgICBpZiAoZ29uZUNoZWNrVGltZXIpIHJldHVybjsKICAgICAg
ICBnb25lQ2hlY2tUaW1lciA9IHNldFRpbWVvdXQoKCkgPT4gewogICAgICAgICAgICBnb25lQ2hlY2tU
aW1lciA9IDA7CiAgICAgICAgICAgIGNvbnN0IG5vZGVzID0gWy4uLmxpc3RFbC5xdWVyeVNlbGVjdG9y
QWxsKCcuaXRtJyldLmZpbHRlcihuID0+IG4uX2ZpbGVQYXRocyAmJiBuLl9maWxlUGF0aHMubGVuZ3Ro
KTsKICAgICAgICAgICAgaWYgKCFub2Rlcy5sZW5ndGgpIHJldHVybjsKICAgICAgICAgICAgY29uc3Qg
dW5pcXVlID0gW107CiAgICAgICAgICAgIGNvbnN0IHNlZW4gPSBuZXcgU2V0KCk7CiAgICAgICAgICAg
IG5vZGVzLmZvckVhY2gobiA9PiB7CiAgICAgICAgICAgICAgICBuLl9maWxlUGF0aHMuZm9yRWFjaChw
ID0+IHsKICAgICAgICAgICAgICAgICAgICBjb25zdCBwYXRoID0gU3RyaW5nKHAgfHwgJycpOwogICAg
ICAgICAgICAgICAgICAgIGlmICghcGF0aCB8fCBzZWVuLmhhcyhwYXRoKSkgcmV0dXJuOwogICAgICAg
ICAgICAgICAgICAgIHNlZW4uYWRkKHBhdGgpOwogICAgICAgICAgICAgICAgICAgIHVuaXF1ZS5wdXNo
KHBhdGgpOwogICAgICAgICAgICAgICAgfSk7CiAgICAgICAgICAgIH0pOwogICAgICAgICAgICBjb25z
dCByb3dzID0gY2hlY2tGaWxlUGF0aHModW5pcXVlKTsKICAgICAgICAgICAgY29uc3QgYnlQYXRoID0g
bmV3IE1hcCgpOwogICAgICAgICAgICByb3dzLmZvckVhY2gociA9PiBieVBhdGguc2V0KFN0cmluZyhy
LnBhdGggfHwgJycpLCByKSk7CiAgICAgICAgICAgIG5vZGVzLmZvckVhY2gobiA9PiB7CiAgICAgICAg
ICAgICAgICBjb25zdCBwYXRoUm93cyA9IG4uX2ZpbGVQYXRocy5tYXAocCA9PiB7CiAgICAgICAgICAg
ICAgICAgICAgY29uc3QgaGl0ID0gYnlQYXRoLmdldChTdHJpbmcocCB8fCAnJykpOwogICAgICAgICAg
ICAgICAgICAgIHJldHVybiBoaXQgfHwgeyBwYXRoOiBwLCBleGlzdHM6IHRydWUsIGlzRGlyOiBmYWxz
ZSB9OwogICAgICAgICAgICAgICAgfSk7CiAgICAgICAgICAgICAgICBuLl9wYXRoUm93cyA9IHBhdGhS
b3dzOwogICAgICAgICAgICAgICAgY29uc3QgYWxsR29uZSA9IHBhdGhSb3dzLmxlbmd0aCA+IDAgJiYg
cGF0aFJvd3MuZXZlcnkociA9PiByLmV4aXN0cyA9PT0gZmFsc2UpOwogICAgICAgICAgICAgICAgbi5j
bGFzc0xpc3QudG9nZ2xlKCdnb25lJywgYWxsR29uZSk7CiAgICAgICAgICAgIH0pOwogICAgICAgIH0s
IDQwMCk7CiAgICB9CiAgICBmdW5jdGlvbiBmaWxsRmlsZURldGFpbFBhbmVsKGNvbnRhaW5lciwgcm93
cykgewogICAgICAgIGNvbnRhaW5lci5pbm5lckhUTUwgPSAnJzsKICAgICAgICBpZiAoIXJvd3MubGVu
Z3RoKSB7CiAgICAgICAgICAgIGNvbnN0IGVtcHR5ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2
Jyk7CiAgICAgICAgICAgIGVtcHR5LmNsYXNzTmFtZSA9ICdmZC1wYXRoJzsKICAgICAgICAgICAgZW1w
dHkudGV4dENvbnRlbnQgPSAn5peg6Lev5b6EJzsKICAgICAgICAgICAgY29udGFpbmVyLmFwcGVuZENo
aWxkKGVtcHR5KTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICByb3dzLmZvckVh
Y2gociA9PiB7CiAgICAgICAgICAgIGNvbnN0IHBhdGggPSBTdHJpbmcoci5wYXRoIHx8ICcnKTsKICAg
ICAgICAgICAgY29uc3QgbWlzc2luZyA9IHIuZXhpc3RzID09PSBmYWxzZTsKICAgICAgICAgICAgY29u
c3QgYmxvY2sgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgYmxvY2su
Y2xhc3NOYW1lID0gJ2ZkLWJsb2NrJzsKCiAgICAgICAgICAgIGNvbnN0IHBhdGhFbCA9IGRvY3VtZW50
LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBwYXRoRWwuY2xhc3NOYW1lID0gJ2ZkLXBh
dGgnICsgKG1pc3NpbmcgPyAnIGRlYWQnIDogJyBsaXZlJyk7CiAgICAgICAgICAgIHBhdGhFbC50ZXh0
Q29udGVudCA9IHBhdGggfHwgJyjnqbrot6/lvoQpJzsKICAgICAgICAgICAgaWYgKCFtaXNzaW5nKSB7
CiAgICAgICAgICAgICAgICBwYXRoRWwub25jbGljayA9IGUgPT4gewogICAgICAgICAgICAgICAgICAg
IGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigp
OwogICAgICAgICAgICAgICAgICAgIGFoaygnb3BlblBhdGgnLCBwYXRoKTsKICAgICAgICAgICAgICAg
IH07CiAgICAgICAgICAgIH0KICAgICAgICAgICAgYmxvY2suYXBwZW5kQ2hpbGQocGF0aEVsKTsKCiAg
ICAgICAgICAgIGNvbnN0IGFjdGlvbnMgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAg
ICAgICAgICAgYWN0aW9ucy5jbGFzc05hbWUgPSAnZmQtYWN0aW9ucyc7CgogICAgICAgICAgICBjb25z
dCBjb3B5QnRuID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnYnV0dG9uJyk7CiAgICAgICAgICAgIGNv
cHlCdG4udHlwZSA9ICdidXR0b24nOwogICAgICAgICAgICBjb3B5QnRuLmNsYXNzTmFtZSA9ICdmZC1i
dG4nOwogICAgICAgICAgICBjb3B5QnRuLmlubmVySFRNTCA9ICc8c3BhbiBjbGFzcz0iZmQtaWNvIj7w
n5SXPC9zcGFuPjxzcGFuIGNsYXNzPSJmZC10eHQiPuWkjeWItui3r+W+hDwvc3Bhbj4nOwogICAgICAg
ICAgICBjb3B5QnRuLm9uY2xpY2sgPSBlID0+IHsKICAgICAgICAgICAgICAgIGUucHJldmVudERlZmF1
bHQoKTsKICAgICAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgICAgICBh
aGsoJ2NvcHlQYXRoJywgcGF0aCk7CiAgICAgICAgICAgICAgICBjb3B5QnRuLnF1ZXJ5U2VsZWN0b3Io
Jy5mZC10eHQnKS50ZXh0Q29udGVudCA9ICflt7LlpI3liLYnOwogICAgICAgICAgICAgICAgY29weUJ0
bi5jbGFzc0xpc3QuYWRkKCdvaycpOwogICAgICAgICAgICAgICAgc2V0VGltZW91dCgoKSA9PiB7CiAg
ICAgICAgICAgICAgICAgICAgY29weUJ0bi5xdWVyeVNlbGVjdG9yKCcuZmQtdHh0JykudGV4dENvbnRl
bnQgPSAn5aSN5Yi26Lev5b6EJzsKICAgICAgICAgICAgICAgICAgICBjb3B5QnRuLmNsYXNzTGlzdC5y
ZW1vdmUoJ29rJyk7CiAgICAgICAgICAgICAgICB9LCAxMjAwKTsKICAgICAgICAgICAgfTsKICAgICAg
ICAgICAgYWN0aW9ucy5hcHBlbmRDaGlsZChjb3B5QnRuKTsKCiAgICAgICAgICAgIGNvbnN0IGZvbGRl
ckJ0biA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2J1dHRvbicpOwogICAgICAgICAgICBmb2xkZXJC
dG4udHlwZSA9ICdidXR0b24nOwogICAgICAgICAgICBmb2xkZXJCdG4uY2xhc3NOYW1lID0gJ2ZkLWJ0
bic7CiAgICAgICAgICAgIGZvbGRlckJ0bi5pbm5lckhUTUwgPSAnPHNwYW4gY2xhc3M9ImZkLWljbyI+
8J+Tgjwvc3Bhbj48c3BhbiBjbGFzcz0iZmQtdHh0Ij7miZPlvIDmiYDlnKjmlofku7blpLk8L3NwYW4+
JzsKICAgICAgICAgICAgZm9sZGVyQnRuLm9uY2xpY2sgPSBlID0+IHsKICAgICAgICAgICAgICAgIGUu
cHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAg
ICAgICAgICAgICBhaGsoJ29wZW5Gb2xkZXInLCBwYXRoKTsKICAgICAgICAgICAgfTsKICAgICAgICAg
ICAgYWN0aW9ucy5hcHBlbmRDaGlsZChmb2xkZXJCdG4pOwoKICAgICAgICAgICAgYmxvY2suYXBwZW5k
Q2hpbGQoYWN0aW9ucyk7CiAgICAgICAgICAgIGNvbnRhaW5lci5hcHBlbmRDaGlsZChibG9jayk7CiAg
ICAgICAgfSk7CiAgICB9CgogICAgY29uc3QgY3R4RWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgn
Y3R4Jyk7CiAgICBmdW5jdGlvbiBzaG93Q3R4KHgsIHksIGMpIHsKICAgICAgICBjdHhDbGlwID0gYzsK
ICAgICAgICBzZWxlY3RlZElkID0gYy5pZDsKICAgICAgICByYW5nZUFuY2hvcklkID0gYy5pZDsKICAg
ICAgICByYW5nZUFuY2hvckNsaWNrZWQgPSB0cnVlOwogICAgICAgIGNvbnN0IGNsZWFyQnRuID0gZG9j
dW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtY2xlYXItcGFzdGVkJyk7CiAgICAgICAgaWYgKGNsZWFyQnRu
KSBjbGVhckJ0bi5zdHlsZS5kaXNwbGF5ID0gaXNQYXN0ZWQoYykgPyAnJyA6ICdub25lJzsKCiAgICAg
ICAgY29uc3QgcGluQnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtcGluJyk7CiAgICAgICAg
aWYgKHBpbkJ0bikgewogICAgICAgICAgICBjb25zdCBvbiA9IGlzUGlubmVkKGMpOwogICAgICAgICAg
ICBwaW5CdG4uaW5uZXJIVE1MID0gb24KICAgICAgICAgICAgICAgID8gJzxzcGFuIGNsYXNzPSJjLWlj
byI+4piFPC9zcGFuPuWPlua2iOaUtuiXjycKICAgICAgICAgICAgICAgIDogJzxzcGFuIGNsYXNzPSJj
LWljbyI+4piFPC9zcGFuPuaUtuiXjyc7CiAgICAgICAgfQogICAgICAgIGNvbnN0IHRpdGxlQnRuID0g
ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtdGl0bGUnKTsKICAgICAgICBpZiAodGl0bGVCdG4pIHsK
ICAgICAgICAgICAgY29uc3Qgc2hvd1RpdGxlID0gaXNQaW5uZWQoYykgfHwgY3VyVGFiID09PSAncGlu
bmVkJzsKICAgICAgICAgICAgdGl0bGVCdG4uc3R5bGUuZGlzcGxheSA9IHNob3dUaXRsZSA/ICcnIDog
J25vbmUnOwogICAgICAgICAgICBpZiAoc2hvd1RpdGxlKQogICAgICAgICAgICAgICAgdGl0bGVCdG4u
aW5uZXJIVE1MID0gKFN0cmluZyhjLmZhdlRpdGxlIHx8ICcnKS50cmltKCkgPyAnPHNwYW4gY2xhc3M9
ImMtaWNvIj7inI48L3NwYW4+57yW6L6R5qCH6aKYJyA6ICc8c3BhbiBjbGFzcz0iYy1pY28iPuKcjjwv
c3Bhbj7orr7nva7moIfpopgnKTsKICAgICAgICB9CiAgICAgICAgY29uc3QgbWVyZ2VCdG4gPSBkb2N1
bWVudC5nZXRFbGVtZW50QnlJZCgnYy1tZXJnZScpOwogICAgICAgIGNvbnN0IHVubWVyZ2VCdG4gPSBk
b2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYy11bm1lcmdlJyk7CiAgICAgICAgY29uc3Qgb25QaW5uZWQg
PSBjdXJUYWIgPT09ICdwaW5uZWQnOwogICAgICAgIGlmIChtZXJnZUJ0bikKICAgICAgICAgICAgbWVy
Z2VCdG4uc3R5bGUuZGlzcGxheSA9IChvblBpbm5lZCAmJiBtdWx0aUlkcy5sZW5ndGggPj0gMikgPyAn
JyA6ICdub25lJzsKICAgICAgICBpZiAodW5tZXJnZUJ0bikKICAgICAgICAgICAgdW5tZXJnZUJ0bi5z
dHlsZS5kaXNwbGF5ID0gKG9uUGlubmVkICYmIGZhdkdyb3VwT2YoYykpID8gJycgOiAnbm9uZSc7CiAg
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
ICAgICBtYXJrUGFzdGVkTG9jYWwoaWRzKTsKICAgICAgICAgICAgICAgIGFoaygncGFzdGVNYW55Jywg
aWRzLmpvaW4oJywnKSk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAg
ICAgICAgaWYgKG11bHRpSWRzLmxlbmd0aCA9PT0gMSkgewogICAgICAgICAgICAgICAgY29uc3QgaWQg
PSBtdWx0aUlkc1swXTsKICAgICAgICAgICAgICAgIGNsZWFyTXVsdGkoKTsKICAgICAgICAgICAgICAg
IG1hcmtQYXN0ZWRMb2NhbChpZCk7CiAgICAgICAgICAgICAgICBhaGsoJ3Bhc3RlJywgU3RyaW5nKGlk
KSk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgY29uc3Qg
YyA9IHZpc1tzZWxlY3RlZEluZGV4KCldOwogICAgICAgICAgICBpZiAoYykgewogICAgICAgICAgICAg
ICAgbWFya1Bhc3RlZExvY2FsKGMuaWQpOwogICAgICAgICAgICAgICAgYWhrKCdwYXN0ZScsIFN0cmlu
ZyhjLmlkKSk7CiAgICAgICAgICAgIH0KICAgICAgICB9IGVsc2UgaWYgKC9eWzEtOV0kLy50ZXN0KGUu
a2V5KSkgewogICAgICAgICAgICBjb25zdCBjID0gdmlzWytlLmtleSAtIDFdOwogICAgICAgICAgICBp
ZiAoYykgewogICAgICAgICAgICAgICAgbWFya1Bhc3RlZExvY2FsKGMuaWQpOwogICAgICAgICAgICAg
ICAgYWhrKCdwYXN0ZScsIFN0cmluZyhjLmlkKSk7CiAgICAgICAgICAgIH0KICAgICAgICB9CiAgICB9
KTsKCiAgICB3aW5kb3cuX19uYXYgPSBkaXIgPT4gewogICAgICAgIGNvbnN0IHZpcyA9ICh0eXBlb2Yg
bmF2TGlzdCA9PT0gJ2Z1bmN0aW9uJyA/IG5hdkxpc3QoKSA6IHZpc2libGVMaXN0KCkpOwogICAgICAg
IGlmICghdmlzLmxlbmd0aCAmJiBkaXIgIT09ICd0YWInICYmIGRpciAhPT0gJ3RhYlByZXYnKSByZXR1
cm47CiAgICAgICAgbGV0IGlkeCA9IHNlbGVjdGVkSW5kZXgoKTsKICAgICAgICBpZiAoaWR4IDwgMCkg
aWR4ID0gMDsKICAgICAgICBpZiAoZGlyID09PSAndXAnKSBzZWxlY3RCeUluZGV4KGlkeCAtIDEpOwog
ICAgICAgIGVsc2UgaWYgKGRpciA9PT0gJ2Rvd24nKSBzZWxlY3RCeUluZGV4KGlkeCArIDEpOwogICAg
ICAgIGVsc2UgaWYgKGRpciA9PT0gJ2VudGVyJykgewogICAgICAgICAgICBpZiAocGlubmVkVUkpIHJl
dHVybjsKICAgICAgICAgICAgX19wcmVwUGFzdGUoKTsKICAgICAgICAgICAgaWYgKG11bHRpSWRzLmxl
bmd0aCA+IDEpIHsKICAgICAgICAgICAgICAgIGNvbnN0IGlkcyA9IG11bHRpSWRzLnNsaWNlKCk7CiAg
ICAgICAgICAgICAgICBjbGVhck11bHRpKCk7CiAgICAgICAgICAgICAgICBtYXJrUGFzdGVkTG9jYWwo
aWRzKTsKICAgICAgICAgICAgICAgIGFoaygncGFzdGVNYW55JywgaWRzLmpvaW4oJywnKSk7CiAgICAg
ICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKG11bHRpSWRzLmxl
bmd0aCA9PT0gMSkgewogICAgICAgICAgICAgICAgY29uc3QgaWQgPSBtdWx0aUlkc1swXTsKICAgICAg
ICAgICAgICAgIGNsZWFyTXVsdGkoKTsKICAgICAgICAgICAgICAgIG1hcmtQYXN0ZWRMb2NhbChpZCk7
CiAgICAgICAgICAgICAgICBhaGsoJ3Bhc3RlJywgU3RyaW5nKGlkKSk7CiAgICAgICAgICAgICAgICBy
ZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgY29uc3QgYyA9IHZpc1tzZWxlY3RlZEluZGV4
KCldOwogICAgICAgICAgICBpZiAoYykgewogICAgICAgICAgICAgICAgbWFya1Bhc3RlZExvY2FsKGMu
aWQpOwogICAgICAgICAgICAgICAgYWhrKCdwYXN0ZScsIFN0cmluZyhjLmlkKSk7CiAgICAgICAgICAg
IH0KICAgICAgICB9CiAgICB9OwoKICAgIC8vIEFISyBFbnRlciBob3RrZXkgbGFuZHMgaGVyZSAoV2Vi
VmlldyBtYXkgbm90IHJlY2VpdmUgdGhlIGtleSB3aGlsZSB1bnBpbm5lZCkKICAgIHdpbmRvdy5fX2Vk
aXRUaXRsZSA9ICgpID0+IHsKICAgICAgICBsZXQgYyA9IG51bGw7CiAgICAgICAgaWYgKHNlbGVjdGVk
SWQpCiAgICAgICAgICAgIGMgPSBhbGxDbGlwcy5maW5kKHggPT4gK3guaWQgPT09ICtzZWxlY3RlZElk
KSB8fCBudWxsOwogICAgICAgIGlmICghYyAmJiBjdHhDbGlwKQogICAgICAgICAgICBjID0gY3R4Q2xp
cDsKICAgICAgICBpZiAoIWMpIHsKICAgICAgICAgICAgY29uc3QgdmlzID0gdmlzaWJsZUxpc3QoKTsK
ICAgICAgICAgICAgaWYgKHZpcy5sZW5ndGgpIGMgPSB2aXNbMF07CiAgICAgICAgfQogICAgICAgIGlm
ICghYykgcmV0dXJuOwogICAgICAgIG9wZW5UaXRsZURsZyhjKTsKICAgIH07CgogICAgd2luZG93Ll9f
b25FbnRlciA9ICgpID0+IHsKICAgICAgICBjb25zdCB0ZCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlk
KCd0aXRsZS1kbGcnKTsKICAgICAgICBpZiAodGQgJiYgdGQuY2xhc3NMaXN0LmNvbnRhaW5zKCdvbicp
KSB7CiAgICAgICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0aXRsZS1vaycpPy5jbGljaygp
OwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGlmIChkb2N1bWVudC5hY3RpdmVF
bGVtZW50Py5pZCA9PT0gJ3RpdGxlLWlucHV0JykgewogICAgICAgICAgICBkb2N1bWVudC5nZXRFbGVt
ZW50QnlJZCgndGl0bGUtb2snKT8uY2xpY2soKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0K
ICAgICAgICAvLyDlm7rlrprml7blm57ovabkuI3nspjotLQKICAgICAgICBpZiAocGlubmVkVUkpIHJl
dHVybjsKICAgICAgICAvLyBUeXBpbmcgaW4gc2VhcmNoOiBFbnRlciBzaG91bGQgcGFzdGUgc2VsZWN0
ZWQgaXRlbQogICAgICAgIGlmIChkb2N1bWVudC5hY3RpdmVFbGVtZW50Py5pZCA9PT0gJ3NlYXJjaCcp
IHsKICAgICAgICAgICAgd2luZG93Ll9fbmF2ICYmIHdpbmRvdy5fX25hdignZW50ZXInKTsKICAgICAg
ICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICB3aW5kb3cuX19uYXYgJiYgd2luZG93Ll9fbmF2
KCdlbnRlcicpOwogICAgfTsKCiAgICB3aW5kb3cuX19jeWNsZVRhYiA9IGRpciA9PiB7CiAgICAgICAg
Y29uc3QgaSA9IE1hdGgubWF4KDAsIFRBQl9PUkRFUi5pbmRleE9mKGN1clRhYikpOwogICAgICAgIGNv
bnN0IG5leHQgPSBUQUJfT1JERVJbKGkgKyAoZGlyIHwgMCkgKyBUQUJfT1JERVIubGVuZ3RoICogMTAp
ICUgVEFCX09SREVSLmxlbmd0aF07CiAgICAgICAgc2V0VGFiKG5leHQpOwogICAgfTsKICAgIHdpbmRv
dy5fX29uUGFuZWxTaG93ID0gKGtlZXBTZWFyY2gpID0+IHsKICAgICAgICAvLyBEbyBOT1QgZm9jdXMg
V2ViVmlldyDigJQga2VlcCBlZGl0b3IgY2FyZXQvZm9jdXMgKEFISyBoYW5kbGVzIGtleXMgdmlhICNI
b3RJZikKICAgICAgICAvLyBXaW4rVjogY29sbGFwc2Ugc2VhcmNoLiA/PyBzZWFyY2g6IGtlZXAvb3Bl
biBzZWFyY2ggYm94LgogICAgICAgIGtlZXBTZWFyY2ggPSAhIWtlZXBTZWFyY2g7CiAgICAgICAgdHJ5
IHsgaGlkZUN0eCgpOyB9IGNhdGNoIHt9CiAgICAgICAgdHJ5IHsgY2xvc2VUaXRsZURsZygpOyB9IGNh
dGNoIHt9CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgY29uc3Qgd3JhcCA9IGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCdzZWFyY2gtd3JhcCcpOwogICAgICAgICAgICBjb25zdCBzcmNoID0gZG9jdW1lbnQu
Z2V0RWxlbWVudEJ5SWQoJ3NlYXJjaCcpOwogICAgICAgICAgICBjb25zdCBzY2xyID0gZG9jdW1lbnQu
Z2V0RWxlbWVudEJ5SWQoJ3NlYXJjaC1jbHInKTsKICAgICAgICAgICAgaWYgKCFrZWVwU2VhcmNoKSB7
CiAgICAgICAgICAgICAgICBpZiAod3JhcCkgd3JhcC5jbGFzc0xpc3QucmVtb3ZlKCdvcGVuJyk7CiAg
ICAgICAgICAgICAgICBpZiAoc3JjaCkgewogICAgICAgICAgICAgICAgICAgIHNyY2gudmFsdWUgPSAn
JzsKICAgICAgICAgICAgICAgICAgICBzcmNoLmNsYXNzTGlzdC5yZW1vdmUoJ2hhcy12YWwnKTsKICAg
ICAgICAgICAgICAgICAgICB0cnkgeyBzcmNoLmJsdXIoKTsgfSBjYXRjaCB7fQogICAgICAgICAgICAg
ICAgfQogICAgICAgICAgICAgICAgaWYgKHNjbHIpIHNjbHIuc3R5bGUuZGlzcGxheSA9ICdub25lJzsK
ICAgICAgICAgICAgICAgIHF1ZXJ5ID0gJyc7CiAgICAgICAgICAgICAgICB3aW5kb3cuX19ob3N0Rmls
dGVyZWQgPSBmYWxzZTsKICAgICAgICAgICAgICAgIHdpbmRvdy5fX2hvc3RGaWx0ZXJRID0gJyc7CiAg
ICAgICAgICAgICAgICAvLyBXaW4rVu+8mueri+WIu+eUqOacqui/h+a7pOe8k+WtmOmTuuWIl+ihqO+8
jOmBv+WFjeWFiOmXqui/h+a7pOe7k+aenC/nqbrlo7Plho3nrYkgU2V0VmlldwogICAgICAgICAgICAg
ICAgdHJ5IHsKICAgICAgICAgICAgICAgICAgICBjb25zdCBoaXQgPSB2aWV3TWVtLmdldCh2aWV3TWVt
S2V5KCdhbGwnLCAnJywgZmFsc2UpKTsKICAgICAgICAgICAgICAgICAgICBpZiAoaGl0ICYmIEFycmF5
LmlzQXJyYXkoaGl0Lml0ZW1zKSAmJiBoaXQuaXRlbXMubGVuZ3RoKSB7CiAgICAgICAgICAgICAgICAg
ICAgICAgIGFsbENsaXBzID0gaGl0Lml0ZW1zLnNsaWNlKCk7CiAgICAgICAgICAgICAgICAgICAgICAg
IGRpc2tUb3RhbCA9IE51bWJlcihoaXQudG90YWwpIHx8IGhpdC5pdGVtcy5sZW5ndGg7CiAgICAgICAg
ICAgICAgICAgICAgICAgIHdpbmRvdy5fX2RhdGFSZWFkeSA9IHRydWU7CiAgICAgICAgICAgICAgICAg
ICAgICAgIGhvc3RQdXNoZWRPbmNlID0gdHJ1ZTsKICAgICAgICAgICAgICAgICAgICAgICAgc2F3Tm9u
RW1wdHkgPSB0cnVlOwogICAgICAgICAgICAgICAgICAgICAgICBjbGVhcldhaXRpbmdEYXRhKCk7CiAg
ICAgICAgICAgICAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgICAgICAgICAgICAgc2NoZWR1bGVE
ZWxheWVkU2tlbCgpOwogICAgICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgIH0gY2F0Y2gg
ewogICAgICAgICAgICAgICAgICAgIHNjaGVkdWxlRGVsYXllZFNrZWwoKTsKICAgICAgICAgICAgICAg
IH0KICAgICAgICAgICAgfSBlbHNlIGlmICh3cmFwKSB7CiAgICAgICAgICAgICAgICB3cmFwLmNsYXNz
TGlzdC5hZGQoJ29wZW4nKTsKICAgICAgICAgICAgICAgIGlmIChzcmNoICYmIHNyY2gudmFsdWUpCiAg
ICAgICAgICAgICAgICAgICAgcXVlcnkgPSBzcmNoLnZhbHVlOwogICAgICAgICAgICAgICAgLy8gPz8g
5pCc57Si77ya5Zyo5Li75py66L+H5ruk57uT5p6c5Yiw6L6+5YmN77yM5YWI5oyJ5YWz6ZSu5a2X5pys
5Zyw5ruk77yM56aB5q2i6Zeq5Ye644CM5YWo6YOo44CNCiAgICAgICAgICAgICAgICBpZiAoU3RyaW5n
KHF1ZXJ5IHx8ICcnKS50cmltKCkpIHsKICAgICAgICAgICAgICAgICAgICB3aW5kb3cuX19ob3N0Rmls
dGVyZWQgPSBmYWxzZTsKICAgICAgICAgICAgICAgICAgICB3aW5kb3cuX19ob3N0RmlsdGVyUSA9ICcn
OwogICAgICAgICAgICAgICAgfQogICAgICAgICAgICB9CiAgICAgICAgICAgIHRvZGF5T25seSA9IGZh
bHNlOwogICAgICAgICAgICB0cnkgewogICAgICAgICAgICAgICAgY29uc3QgYnRuVG9kYXkgPSBkb2N1
bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLXRvZGF5Jyk7CiAgICAgICAgICAgICAgICBpZiAoYnRuVG9k
YXkpIGJ0blRvZGF5LmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgICAgIH0gY2F0Y2gge30K
ICAgICAgICAgICAgY3VyVGFiID0gJ2FsbCc7CiAgICAgICAgICAgIGxvYWRpbmdNb3JlID0gZmFsc2U7
CiAgICAgICAgICAgIG1hcmtUYWIoJ2FsbCcpOwogICAgICAgICAgICAvLyDkuI3opoEgYWhrKCdibHVy
UGFuZWwnKe+8muS8mui3nyBTaG93UGFuZWwg5oqi54Sm54K577yMV2luK1YvPz8g6YO95a655piT6Zeq
44CB5Lmx6LezCiAgICAgICAgICAgIHJlbmRlcigpOwogICAgICAgICAgICAvLyDlkIzmraXlvZPliY0g
dGFiL3F1ZXJ5IOWIsCBBSEvvvIg/PyDmm77lj6rnlKggdmlld1RhYiDmkJzplJnpobXvvIkKICAgICAg
ICAgICAgcmVxdWVzdFZpZXcoKTsKICAgICAgICB9IGNhdGNoIHt9CiAgICAgICAgc2VsZWN0Rmlyc3RP
blNob3cgPSB0cnVlOwogICAgICAgIGxvY2F0ZUFjdGl2ZSA9IGZhbHNlOwogICAgICAgIHVwZGF0ZUxv
Y2F0ZUJ0bigpOwogICAgICAgIGNsZWFyTXVsdGkoKTsKICAgICAgICBjb25zdCB2aXMgPSB2aXNpYmxl
TGlzdCgpOwogICAgICAgIGlmICh2aXMubGVuZ3RoKSB7CiAgICAgICAgICAgIHNlbGVjdGVkSWQgPSB2
aXNbMF0uaWQ7CiAgICAgICAgICAgIHJhbmdlQW5jaG9ySWQgPSBzZWxlY3RlZElkOwogICAgICAgICAg
ICByYW5nZUFuY2hvckNsaWNrZWQgPSBmYWxzZTsKICAgICAgICAgICAgbGlzdEVsLnNjcm9sbFRvcCA9
IDA7CiAgICAgICAgfQogICAgICAgIHN5bmNJdGVtSGlnaGxpZ2h0KCk7CiAgICB9OwoKICAgIGZ1bmN0
aW9uIGN0eEJpbmQoaWQsIGZuKSB7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaWQpLmFk
ZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9u
KCk7CiAgICAgICAgICAgIGlmIChjdHhDbGlwKSBmbihjdHhDbGlwKTsKICAgICAgICAgICAgaGlkZUN0
eCgpOwogICAgICAgIH0pOwogICAgfQogICAgY3R4QmluZCgnYy1jb3B5JywgIGMgPT4gYWhrKCdjb3B5
QnlJZCcsICAgICBTdHJpbmcoYy5pZCkpKTsKICAgIGN0eEJpbmQoJ2MtcGFzdGUnLCBjID0+IHsKICAg
ICAgICBtYXJrUGFzdGVkTG9jYWwoYy5pZCk7CiAgICAgICAgYWhrKCdwYXN0ZScsIFN0cmluZyhjLmlk
KSk7CiAgICB9KTsKICAgIGN0eEJpbmQoJ2MtcGluJywgICBjID0+IGFoaygncGluJywgICAgICAgICAg
IFN0cmluZyhjLmlkKSkpOwogICAgY3R4QmluZCgnYy10b3AnLCAgIGMgPT4gYWhrKCdtb3ZlVG9Ub3An
LCAgICAgU3RyaW5nKGMuaWQpKSk7CiAgICBjdHhCaW5kKCdjLWNsZWFyLXBhc3RlZCcsIGMgPT4gYWhr
KCdjbGVhclBhc3RlZCcsIFN0cmluZyhjLmlkKSkpOwogICAgY3R4QmluZCgnYy1kZWwnLCAgIGMgPT4g
ewogICAgICAgIC8vIOacrOWcsOWFiOWIoO+8jOeVjOmdouS4jeWNoe+8m0FISyDlkI7lj7DokL3nm5gK
ICAgICAgICB0cnkgewogICAgICAgICAgICBjb25zdCBpZCA9ICtjLmlkOwogICAgICAgICAgICBhbGxD
bGlwcyA9IGFsbENsaXBzLmZpbHRlcih4ID0+ICt4LmlkICE9PSBpZCk7CiAgICAgICAgICAgIGRpc2tU
b3RhbCA9IE1hdGgubWF4KDAsIChOdW1iZXIoZGlza1RvdGFsKSB8fCAwKSAtIDEpOwogICAgICAgICAg
ICBpZiAoK3NlbGVjdGVkSWQgPT09IGlkKSBzZWxlY3RlZElkID0gYWxsQ2xpcHMubGVuZ3RoID8gYWxs
Q2xpcHNbMF0uaWQgOiAwOwogICAgICAgICAgICByZW5kZXIoKTsKICAgICAgICB9IGNhdGNoIHt9CiAg
ICAgICAgYWhrKCdkZWxldGUnLCBTdHJpbmcoYy5pZCkpOwogICAgfSk7CiAgICBjdHhCaW5kKCdjLXRp
dGxlJywgYyA9PiBvcGVuVGl0bGVEbGcoYykpOwogICAgY3R4QmluZCgnYy1tZXJnZScsIGMgPT4gewog
ICAgICAgIGNvbnN0IGlkcyA9IChtdWx0aUlkcy5sZW5ndGggPj0gMikgPyBtdWx0aUlkcy5zbGljZSgp
IDogW107CiAgICAgICAgaWYgKGlkcy5sZW5ndGggPCAyKSByZXR1cm47CiAgICAgICAgaWYgKCFpZHMu
aW5jbHVkZXMoK2MuaWQpKSBpZHMucHVzaCgrYy5pZCk7CiAgICAgICAgYWhrKCdtZXJnZUZhdicsIGlk
cy5qb2luKCcsJykpOwogICAgICAgIGNsZWFyTXVsdGkoKTsKICAgIH0pOwogICAgY3R4QmluZCgnYy11
bm1lcmdlJywgYyA9PiB7CiAgICAgICAgYWhrKCd1bm1lcmdlRmF2JywgU3RyaW5nKGMuaWQpKTsKICAg
ICAgICBjbGVhck11bHRpKCk7CiAgICB9KTsKCiAgICBjb25zdCB0aXRsZURsZyA9IGRvY3VtZW50Lmdl
dEVsZW1lbnRCeUlkKCd0aXRsZS1kbGcnKTsKICAgIGNvbnN0IHRpdGxlSW5wdXQgPSBkb2N1bWVudC5n
ZXRFbGVtZW50QnlJZCgndGl0bGUtaW5wdXQnKTsKICAgIGxldCB0aXRsZURsZ0NsaXAgPSBudWxsOwog
ICAgZnVuY3Rpb24gY2xvc2VUaXRsZURsZygpIHsKICAgICAgICBpZiAodGl0bGVEbGcpIHRpdGxlRGxn
LmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgdGl0bGVEbGdDbGlwID0gbnVsbDsKICAgIH0K
ICAgIGZ1bmN0aW9uIG9wZW5UaXRsZURsZyhjKSB7CiAgICAgICAgaGlkZUN0eCgpOwogICAgICAgIHRp
dGxlRGxnQ2xpcCA9IGM7CiAgICAgICAgaWYgKHRpdGxlSW5wdXQpIHRpdGxlSW5wdXQudmFsdWUgPSBT
dHJpbmcoYy5mYXZUaXRsZSB8fCAnJykudHJpbSgpOwogICAgICAgIGlmICh0aXRsZURsZykgdGl0bGVE
bGcuY2xhc3NMaXN0LmFkZCgnb24nKTsKICAgICAgICBhaGsoJ2ZvY3VzUGFuZWwnKTsKICAgICAgICBy
ZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4gewogICAgICAgICAgICB0cnkgeyB0aXRsZUlucHV0LmZv
Y3VzKCk7IHRpdGxlSW5wdXQuc2VsZWN0KCk7IH0gY2F0Y2gge30KICAgICAgICB9KTsKICAgIH0KICAg
IGlmICh0aXRsZURsZykgewogICAgICAgIHRpdGxlRGxnLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywg
ZSA9PiB7CiAgICAgICAgICAgIGlmIChlLnRhcmdldCA9PT0gdGl0bGVEbGcpIGNsb3NlVGl0bGVEbGco
KTsKICAgICAgICB9KTsKICAgIH0KICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0aXRsZS1jYW5j
ZWwnKT8uYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICBlLnN0b3BQcm9wYWdh
dGlvbigpOwogICAgICAgIGNsb3NlVGl0bGVEbGcoKTsKICAgICAgICBhaGsoJ2JsdXJQYW5lbCcpOwog
ICAgfSk7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGl0bGUtb2snKT8uYWRkRXZlbnRMaXN0
ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgIGlm
ICghdGl0bGVEbGdDbGlwKSByZXR1cm47CiAgICAgICAgY29uc3QgdCA9IFN0cmluZyh0aXRsZUlucHV0
Py52YWx1ZSB8fCAnJykudHJpbSgpLnNsaWNlKDAsIDgwKTsKICAgICAgICBjb25zdCBpZCA9IFN0cmlu
Zyh0aXRsZURsZ0NsaXAuaWQpOwogICAgICAgIC8vIE9wdGltaXN0aWMgbG9jYWwgdXBkYXRlCiAgICAg
ICAgY29uc3QgaGl0ID0gYWxsQ2xpcHMuZmluZCh4ID0+ICt4LmlkID09PSAraWQpOwogICAgICAgIGlm
IChoaXQpIGhpdC5mYXZUaXRsZSA9IHQ7CiAgICAgICAgdGl0bGVEbGdDbGlwLmZhdlRpdGxlID0gdDsK
ICAgICAgICBjbG9zZVRpdGxlRGxnKCk7CiAgICAgICAgYWhrKCdzZXRGYXZUaXRsZScsIGlkLCB0KTsK
ICAgICAgICBhaGsoJ2JsdXJQYW5lbCcpOwogICAgICAgIHJlbmRlcigpOwogICAgfSk7CiAgICB0aXRs
ZUlucHV0Py5hZGRFdmVudExpc3RlbmVyKCdrZXlkb3duJywgZSA9PiB7CiAgICAgICAgaWYgKGUua2V5
ID09PSAnRW50ZXInKSB7CiAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAg
ZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgZS5zdG9wSW1tZWRpYXRlUHJvcGFnYXRpb24o
KTsKICAgICAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RpdGxlLW9rJyk/LmNsaWNrKCk7
CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgaWYgKGUua2V5ID09PSAnRXNjYXBl
JykgewogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgIGUuc3RvcFByb3Bh
Z2F0aW9uKCk7CiAgICAgICAgICAgIGNsb3NlVGl0bGVEbGcoKTsKICAgICAgICAgICAgYWhrKCdibHVy
UGFuZWwnKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBlLnN0b3BQcm9wYWdh
dGlvbigpOwogICAgfSwgdHJ1ZSk7CgogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RhYnMnKS5h
ZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGNvbnN0IHRhYiA9IGUudGFyZ2V0
LmNsb3Nlc3QoJy50YWInKTsKICAgICAgICBpZiAoIXRhYiB8fCBlLnRhcmdldC5jbG9zZXN0KCcjdGFi
LWFjdGlvbnMnKSkgcmV0dXJuOwogICAgICAgIHNldFRhYih0YWIuZGF0YXNldC50YWIpOwogICAgfSk7
CgogICAgY29uc3Qgc3JjaFdyYXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLXdyYXAn
KTsKICAgIGNvbnN0IGJ0blNlYXJjaCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tc2VhcmNo
Jyk7CiAgICBjb25zdCBidG5Mb2NhdGUgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLWxvY2F0
ZScpOwogICAgY29uc3QgYnRuVG9kYXkgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLXRvZGF5
Jyk7CiAgICBjb25zdCBzcmNoID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaCcpOwogICAg
Y29uc3Qgc2NsciA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gtY2xyJyk7CiAgICBsZXQg
ZGViOwoKICAgIHVwZGF0ZUxvY2F0ZUJ0bigpOwogICAgaWYgKGJ0bkxvY2F0ZSkgewogICAgICAgIGJ0
bkxvY2F0ZS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgICAgICBlLnN0b3BQ
cm9wYWdhdGlvbigpOwogICAgICAgICAgICBqdW1wVG9MYXN0UGFzdGUoKTsKICAgICAgICB9KTsKICAg
IH0KCiAgICBidG5Ub2RheS5hZGRFdmVudExpc3RlbmVyKCdtb3VzZWRvd24nLCBlID0+IHsKICAgICAg
ICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgIH0pOwog
ICAgYnRuVG9kYXkuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICBlLnN0b3BQ
cm9wYWdhdGlvbigpOwogICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICB0b2RheU9ubHkg
PSAhdG9kYXlPbmx5OwogICAgICAgIGJ0blRvZGF5LmNsYXNzTGlzdC50b2dnbGUoJ29uJywgdG9kYXlP
bmx5KTsKICAgICAgICBsaXN0RWwuc2Nyb2xsVG9wID0gMDsKICAgICAgICByZXF1ZXN0VmlldygpOwog
ICAgICAgIHRyeSB7IHNyY2guZm9jdXMoKTsgfSBjYXRjaCB7fQogICAgfSk7CgogICAgZnVuY3Rpb24g
b3BlblNlYXJjaCgpIHsKICAgICAgICBpZiAoc3JjaFdyYXAuY2xhc3NMaXN0LmNvbnRhaW5zKCdvcGVu
JykpIHsKICAgICAgICAgICAgYWhrKCdmb2N1c1BhbmVsJyk7CiAgICAgICAgICAgIHRyeSB7IHNyY2gu
Zm9jdXMoKTsgfSBjYXRjaCB7fQogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIHNy
Y2hXcmFwLmNsYXNzTGlzdC5hZGQoJ29wZW4nKTsKICAgICAgICAvLyBEZWZhdWx0OiDmiYDmnInpobXm
iZPlvIDmkJzntKLml7bpu5jorqTmkJzlhajpg6gKICAgICAgICBjb25zdCB3YW50VG9kYXkgPSBmYWxz
ZTsKICAgICAgICBpZiAodG9kYXlPbmx5ICE9PSB3YW50VG9kYXkpIHsKICAgICAgICAgICAgdG9kYXlP
bmx5ID0gd2FudFRvZGF5OwogICAgICAgICAgICBidG5Ub2RheS5jbGFzc0xpc3QudG9nZ2xlKCdvbics
IHRvZGF5T25seSk7CiAgICAgICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSAwOwogICAgICAgICAgICBy
ZXF1ZXN0VmlldygpOwogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgIGJ0blRvZGF5LmNsYXNzTGlz
dC50b2dnbGUoJ29uJywgdG9kYXlPbmx5KTsKICAgICAgICB9CiAgICAgICAgYWhrKCdmb2N1c1BhbmVs
Jyk7CiAgICAgICAgcmVxdWVzdEFuaW1hdGlvbkZyYW1lKCgpID0+IHsKICAgICAgICAgICAgdHJ5IHsg
c3JjaC5mb2N1cygpOyB9IGNhdGNoIHt9CiAgICAgICAgfSk7CiAgICB9CiAgICBmdW5jdGlvbiBjbG9z
ZVNlYXJjaFVpKCkgewogICAgICAgIHNyY2hXcmFwLmNsYXNzTGlzdC5yZW1vdmUoJ29wZW4nKTsKICAg
ICAgICBpZiAoIXNyY2gudmFsdWUpIHsKICAgICAgICAgICAgc3JjaC5jbGFzc0xpc3QucmVtb3ZlKCdo
YXMtdmFsJyk7CiAgICAgICAgICAgIHNjbHIuc3R5bGUuZGlzcGxheSA9ICdub25lJzsKICAgICAgICAg
ICAgLy8gTGVhdmluZyBzZWFyY2ggd2l0aCBlbXB0eSBxdWVyeSDihpIgZHJvcCB0b2RheSBmaWx0ZXIK
ICAgICAgICAgICAgaWYgKHRvZGF5T25seSkgewogICAgICAgICAgICAgICAgdG9kYXlPbmx5ID0gZmFs
c2U7CiAgICAgICAgICAgICAgICBidG5Ub2RheS5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAg
ICAgICAgICAgcmVxdWVzdFZpZXcoKTsKICAgICAgICAgICAgfQogICAgICAgIH0KICAgIH0KICAgIHdp
bmRvdy5fX29wZW5TZWFyY2ggPSBvcGVuU2VhcmNoOwogICAgd2luZG93Ll9fcHJlcFR5cGVTZWFyY2gg
PSAoKSA9PiB7CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgY29uc3Qgd3JhcCA9IGRvY3VtZW50Lmdl
dEVsZW1lbnRCeUlkKCdzZWFyY2gtd3JhcCcpOwogICAgICAgICAgICBjb25zdCBzID0gZG9jdW1lbnQu
Z2V0RWxlbWVudEJ5SWQoJ3NlYXJjaCcpOwogICAgICAgICAgICBpZiAod3JhcCAmJiAhd3JhcC5jbGFz
c0xpc3QuY29udGFpbnMoJ29wZW4nKSkgewogICAgICAgICAgICAgICAgd3JhcC5jbGFzc0xpc3QuYWRk
KCdvcGVuJyk7CiAgICAgICAgICAgICAgICB0cnkgewogICAgICAgICAgICAgICAgICAgIGNvbnN0IHdh
bnRUb2RheSA9IGZhbHNlOwogICAgICAgICAgICAgICAgICAgIGlmICh0eXBlb2YgdG9kYXlPbmx5ICE9
PSAndW5kZWZpbmVkJyAmJiB0b2RheU9ubHkgIT09IHdhbnRUb2RheSkgewogICAgICAgICAgICAgICAg
ICAgICAgICB0b2RheU9ubHkgPSB3YW50VG9kYXk7CiAgICAgICAgICAgICAgICAgICAgICAgIGlmICh0
eXBlb2YgYnRuVG9kYXkgIT09ICd1bmRlZmluZWQnICYmIGJ0blRvZGF5KSBidG5Ub2RheS5jbGFzc0xp
c3QudG9nZ2xlKCdvbicsIHRvZGF5T25seSk7CiAgICAgICAgICAgICAgICAgICAgICAgIGlmICh0eXBl
b2YgbGlzdEVsICE9PSAndW5kZWZpbmVkJyAmJiBsaXN0RWwpIGxpc3RFbC5zY3JvbGxUb3AgPSAwOwog
ICAgICAgICAgICAgICAgICAgICAgICBpZiAodHlwZW9mIHJlcXVlc3RWaWV3ID09PSAnZnVuY3Rpb24n
KSBzZXRUaW1lb3V0KHJlcXVlc3RWaWV3LCAwKTsKICAgICAgICAgICAgICAgICAgICB9IGVsc2UgaWYg
KHR5cGVvZiBidG5Ub2RheSAhPT0gJ3VuZGVmaW5lZCcgJiYgYnRuVG9kYXkpIHsKICAgICAgICAgICAg
ICAgICAgICAgICAgYnRuVG9kYXkuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCAhIXRvZGF5T25seSk7CiAg
ICAgICAgICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgfSBjYXRjaCB7fQogICAgICAgICAgICB9
CiAgICAgICAgICAgIC8vID8/IOmVnOWDj+aQnOe0ou+8muS4jeimgSBmb2N1c++8jOmBv+WFjeaKoui1
sOWOn+e8lui+keahhuWFieaghwogICAgICAgIH0gY2F0Y2gge30KICAgIH07CiAgICB3aW5kb3cuX190
eXBlU2VhcmNoID0gKGNoKSA9PiB7CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgd2luZG93Ll9fcHJl
cFR5cGVTZWFyY2ggJiYgd2luZG93Ll9fcHJlcFR5cGVTZWFyY2goKTsKICAgICAgICAgICAgY29uc3Qg
cyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gnKTsKICAgICAgICAgICAgaWYgKCFzKSBy
ZXR1cm47CiAgICAgICAgICAgIHMudmFsdWUgPSBTdHJpbmcocy52YWx1ZSB8fCAnJykgKyBTdHJpbmco
Y2ggPT0gbnVsbCA/ICcnIDogY2gpOwogICAgICAgICAgICBzLmNsYXNzTGlzdC50b2dnbGUoJ2hhcy12
YWwnLCAhIXMudmFsdWUpOwogICAgICAgICAgICBzLmRpc3BhdGNoRXZlbnQobmV3IEV2ZW50KCdpbnB1
dCcsIHsgYnViYmxlczogdHJ1ZSB9KSk7CiAgICAgICAgfSBjYXRjaCB7fQogICAgfTsKICAgIHdpbmRv
dy5fX2Jrc3BTZWFyY2ggPSAoKSA9PiB7CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgd2luZG93Ll9f
cHJlcFR5cGVTZWFyY2ggJiYgd2luZG93Ll9fcHJlcFR5cGVTZWFyY2goKTsKICAgICAgICAgICAgY29u
c3QgcyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gnKTsKICAgICAgICAgICAgaWYgKCFz
KSByZXR1cm47CiAgICAgICAgICAgIGNvbnN0IHYgPSBTdHJpbmcocy52YWx1ZSB8fCAnJyk7CiAgICAg
ICAgICAgIHMudmFsdWUgPSB2Lmxlbmd0aCA/IHYuc2xpY2UoMCwgLTEpIDogJyc7CiAgICAgICAgICAg
IHMuY2xhc3NMaXN0LnRvZ2dsZSgnaGFzLXZhbCcsICEhcy52YWx1ZSk7CiAgICAgICAgICAgIHMuZGlz
cGF0Y2hFdmVudChuZXcgRXZlbnQoJ2lucHV0JywgeyBidWJibGVzOiB0cnVlIH0pKTsKICAgICAgICB9
IGNhdGNoIHt9CiAgICB9OwogICAgd2luZG93Ll9fc2V0U2VhcmNoUXVlcnkgPSAocSkgPT4gewogICAg
ICAgIHRyeSB7CiAgICAgICAgICAgIGNvbnN0IHMgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2Vh
cmNoJyk7CiAgICAgICAgICAgIGlmICghcykgcmV0dXJuOwogICAgICAgICAgICBjb25zdCBuZXh0ID0g
U3RyaW5nKHEgPT0gbnVsbCA/ICcnIDogcSk7CiAgICAgICAgICAgIGNvbnN0IHByZXYgPSBTdHJpbmco
cy52YWx1ZSB8fCAnJyk7CiAgICAgICAgICAgIC8vIOWQjOWFs+mUruWtl+mHjeWkjeaOqOmAge+8muWP
quS/neivgeaQnOe0ouahhuW8gOedgO+8jOemgeatouWGjSByZXF1ZXN0Vmlld++8iOS8muatu+W+queO
r+mXqu+8iQogICAgICAgICAgICBpZiAocHJldiA9PT0gbmV4dCAmJiBTdHJpbmcocXVlcnkgfHwgJycp
ID09PSBuZXh0KSB7CiAgICAgICAgICAgICAgICB0cnkgewogICAgICAgICAgICAgICAgICAgIGNvbnN0
IHdyYXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLXdyYXAnKTsKICAgICAgICAgICAg
ICAgICAgICBpZiAod3JhcCAmJiAhd3JhcC5jbGFzc0xpc3QuY29udGFpbnMoJ29wZW4nKSkKICAgICAg
ICAgICAgICAgICAgICAgICAgd3JhcC5jbGFzc0xpc3QuYWRkKCdvcGVuJyk7CiAgICAgICAgICAgICAg
ICB9IGNhdGNoIHt9CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAg
ICAgLy8g5omT5a2X5Y2z5pe25LiK5bGP77yM5LiO56OB55uY5pCc57Si6Kej6ICmCiAgICAgICAgICAg
IHMudmFsdWUgPSBuZXh0OwogICAgICAgICAgICBzLmNsYXNzTGlzdC50b2dnbGUoJ2hhcy12YWwnLCAh
IXMudmFsdWUpOwogICAgICAgICAgICBjb25zdCBzY2xyID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQo
J3NlYXJjaC1jbHInKTsKICAgICAgICAgICAgaWYgKHNjbHIpIHNjbHIuc3R5bGUuZGlzcGxheSA9IHMu
dmFsdWUgPyAnYmxvY2snIDogJ25vbmUnOwogICAgICAgICAgICBxdWVyeSA9IHMudmFsdWU7CiAgICAg
ICAgICAgIHRyeSB7CiAgICAgICAgICAgICAgICBjb25zdCB3cmFwID0gZG9jdW1lbnQuZ2V0RWxlbWVu
dEJ5SWQoJ3NlYXJjaC13cmFwJyk7CiAgICAgICAgICAgICAgICBpZiAod3JhcCAmJiAhd3JhcC5jbGFz
c0xpc3QuY29udGFpbnMoJ29wZW4nKSkKICAgICAgICAgICAgICAgICAgICB3aW5kb3cuX19wcmVwVHlw
ZVNlYXJjaCAmJiB3aW5kb3cuX19wcmVwVHlwZVNlYXJjaCgpOwogICAgICAgICAgICAgICAgZWxzZSBp
ZiAod3JhcCkKICAgICAgICAgICAgICAgICAgICB3cmFwLmNsYXNzTGlzdC5hZGQoJ29wZW4nKTsKICAg
ICAgICAgICAgfSBjYXRjaCB7fQogICAgICAgICAgICB3aW5kb3cuX19ob3N0RmlsdGVyZWQgPSBmYWxz
ZTsKICAgICAgICAgICAgd2luZG93Ll9faG9zdEZpbHRlclEgPSAnJzsKICAgICAgICAgICAgaWYgKFN0
cmluZyhxdWVyeSB8fCAnJykudHJpbSgpKSB7CiAgICAgICAgICAgICAgICB3YWl0aW5nRGF0YSA9IHRy
dWU7CiAgICAgICAgICAgICAgICB3aW5kb3cuX19kYXRhUmVhZHkgPSBmYWxzZTsKICAgICAgICAgICAg
fQogICAgICAgICAgICB0cnkgewogICAgICAgICAgICAgICAgY29uc3QgY250ID0gZG9jdW1lbnQuZ2V0
RWxlbWVudEJ5SWQoJ2Jhci10eHQnKTsKICAgICAgICAgICAgICAgIGlmIChjbnQgJiYgU3RyaW5nKHF1
ZXJ5IHx8ICcnKS50cmltKCkpCiAgICAgICAgICAgICAgICAgICAgY250LnRleHRDb250ZW50ID0gdmlz
aWJsZUxpc3QoKS5sZW5ndGggKyAnIOadoSc7CiAgICAgICAgICAgIH0gY2F0Y2gge30KICAgICAgICAg
ICAgdHJ5IHsgcmVuZGVyKCk7IH0gY2F0Y2gge30KICAgICAgICAgICAgY2xlYXJUaW1lb3V0KHdpbmRv
dy5fX3FxVmlld0RlYik7CiAgICAgICAgICAgIHdpbmRvdy5fX3FxVmlld0RlYiA9IHNldFRpbWVvdXQo
KCkgPT4gewogICAgICAgICAgICAgICAgd2luZG93Ll9fcXFWaWV3RGViID0gMDsKICAgICAgICAgICAg
ICAgIHJlcXVlc3RWaWV3KCk7CiAgICAgICAgICAgIH0sIDcwKTsKICAgICAgICB9IGNhdGNoIHt9CiAg
ICB9OwogICAgLy8gQ2FwdHVyZSBDdHJsK0YgaW5zaWRlIFdlYlZpZXcgKENocm9taXVtIGZpbmQgaXMg
ZGlzYWJsZWQsIGJ1dCBzdGlsbCBoYW5kbGUgaGVyZSkKICAgIGRvY3VtZW50LmFkZEV2ZW50TGlzdGVu
ZXIoJ2tleWRvd24nLCBlID0+IHsKICAgICAgICBpZiAoKGUuY3RybEtleSB8fCBlLm1ldGFLZXkpICYm
ICFlLmFsdEtleSAmJiAoZS5rZXkgPT09ICdmJyB8fCBlLmtleSA9PT0gJ0YnKSkgewogICAgICAgICAg
ICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAg
ICAgICAgIG9wZW5TZWFyY2goKTsKICAgICAgICB9CiAgICB9LCB0cnVlKTsKICAgIGJ0blNlYXJjaC5h
ZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7
CiAgICAgICAgb3BlblNlYXJjaCgpOwogICAgfSk7CiAgICBsZXQgX19zcmNoQ29tcG9zaW5nID0gZmFs
c2U7CiAgICBjb25zdCBfX2ZsdXNoU2VhcmNoSW5wdXQgPSAoKSA9PiB7CiAgICAgICAgcXVlcnkgPSBz
cmNoLnZhbHVlOwogICAgICAgIHNyY2guY2xhc3NMaXN0LnRvZ2dsZSgnaGFzLXZhbCcsICEhcXVlcnkp
OwogICAgICAgIHNjbHIuc3R5bGUuZGlzcGxheSA9IHF1ZXJ5ID8gJ2Jsb2NrJyA6ICdub25lJzsKICAg
ICAgICBsaXN0RWwuc2Nyb2xsVG9wID0gMDsKICAgICAgICB3aW5kb3cuX19ob3N0RmlsdGVyZWQgPSBm
YWxzZTsKICAgICAgICB3aW5kb3cuX19ob3N0RmlsdGVyUSA9ICcnOwogICAgICAgIHRyeSB7IHJlbmRl
cigpOyB9IGNhdGNoIHt9CiAgICAgICAgY2xlYXJUaW1lb3V0KGRlYik7CiAgICAgICAgZGViID0gc2V0
VGltZW91dChyZXF1ZXN0VmlldywgODApOwogICAgfTsKICAgIHNyY2guYWRkRXZlbnRMaXN0ZW5lcign
Y29tcG9zaXRpb25zdGFydCcsICgpID0+IHsgX19zcmNoQ29tcG9zaW5nID0gdHJ1ZTsgfSk7CiAgICBz
cmNoLmFkZEV2ZW50TGlzdGVuZXIoJ2NvbXBvc2l0aW9uZW5kJywgKCkgPT4gewogICAgICAgIF9fc3Jj
aENvbXBvc2luZyA9IGZhbHNlOwogICAgICAgIF9fZmx1c2hTZWFyY2hJbnB1dCgpOwogICAgfSk7CiAg
ICBzcmNoLmFkZEV2ZW50TGlzdGVuZXIoJ2lucHV0JywgKCkgPT4gewogICAgICAgIGlmIChfX3NyY2hD
b21wb3NpbmcpIHsKICAgICAgICAgICAgcXVlcnkgPSBzcmNoLnZhbHVlOwogICAgICAgICAgICBzcmNo
LmNsYXNzTGlzdC50b2dnbGUoJ2hhcy12YWwnLCAhIXF1ZXJ5KTsKICAgICAgICAgICAgc2Nsci5zdHls
ZS5kaXNwbGF5ID0gcXVlcnkgPyAnYmxvY2snIDogJ25vbmUnOwogICAgICAgICAgICByZXR1cm47CiAg
ICAgICAgfQogICAgICAgIF9fZmx1c2hTZWFyY2hJbnB1dCgpOwogICAgfSk7CiAgICBzcmNoLmFkZEV2
ZW50TGlzdGVuZXIoJ2ZvY3VzJywgKCkgPT4gewogICAgICAgIC8vIElkZW1wb3RlbnQgb24gQUhLIHNp
ZGUg4oCUIHNhZmUsIGJ1dCBhdm9pZCBzcGFtbWluZyBkdXJpbmcgSU1FCiAgICAgICAgdHJ5IHsgYWhr
KCdmb2N1c1BhbmVsJyk7IH0gY2F0Y2gge30KICAgIH0pOwogICAgc3JjaC5hZGRFdmVudExpc3RlbmVy
KCdibHVyJywgKCkgPT4gewogICAgICAgIHNldFRpbWVvdXQoKCkgPT4gewogICAgICAgICAgICBpZiAo
ZG9jdW1lbnQuYWN0aXZlRWxlbWVudCA9PT0gc3JjaCkgcmV0dXJuOwogICAgICAgICAgICBpZiAoZG9j
dW1lbnQuYWN0aXZlRWxlbWVudCA9PT0gc2NsciB8fCAoc2NsciAmJiBzY2xyLmNvbnRhaW5zKGRvY3Vt
ZW50LmFjdGl2ZUVsZW1lbnQpKSkgcmV0dXJuOwogICAgICAgICAgICBpZiAoZG9jdW1lbnQuYWN0aXZl
RWxlbWVudCA9PT0gYnRuVG9kYXkgfHwgKGJ0blRvZGF5ICYmIGJ0blRvZGF5LmNvbnRhaW5zKGRvY3Vt
ZW50LmFjdGl2ZUVsZW1lbnQpKSkgcmV0dXJuOwogICAgICAgICAgICAvLyBJTUUgY2FuZGlkYXRlIFVJ
IHN0ZWFscyBmb2N1cyBicmllZmx5IOKAlCBrZWVwIHNlYXJjaCBpZiBzdGlsbCBjb21wb3NpbmcKICAg
ICAgICAgICAgaWYgKF9fc3JjaENvbXBvc2luZykgcmV0dXJuOwogICAgICAgICAgICBjbG9zZVNlYXJj
aFVpKCk7CiAgICAgICAgICAgIGFoaygnYmx1clBhbmVsJyk7CiAgICAgICAgfSwgMjgwKTsKICAgIH0p
OwogICAgc3JjaC5hZGRFdmVudExpc3RlbmVyKCdrZXlkb3duJywgZSA9PiB7CiAgICAgICAgLy8gQ3Ry
bCtJIC8gQ3RybCtLOiBtb3ZlIGNsaXAgc2VsZWN0aW9uIChub3QgaW5zZXJ0IGNoYXIgLyBicm93c2Vy
IHNob3J0Y3V0KQogICAgICAgIGlmICgoZS5jdHJsS2V5IHx8IGUubWV0YUtleSkgJiYgKGUua2V5ID09
PSAnaScgfHwgZS5rZXkgPT09ICdJJykpIHsKICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwog
ICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICB3aW5kb3cuX19uYXYgJiYg
d2luZG93Ll9fbmF2KCd1cCcpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGlm
ICgoZS5jdHJsS2V5IHx8IGUubWV0YUtleSkgJiYgKGUua2V5ID09PSAnaycgfHwgZS5rZXkgPT09ICdL
JykpIHsKICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICBlLnN0b3BQcm9w
YWdhdGlvbigpOwogICAgICAgICAgICB3aW5kb3cuX19uYXYgJiYgd2luZG93Ll9fbmF2KCdkb3duJyk7
CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgaWYgKGUua2V5ID09PSAnQXJyb3dE
b3duJykgewogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgIGUuc3RvcFBy
b3BhZ2F0aW9uKCk7CiAgICAgICAgICAgIHdpbmRvdy5fX25hdiAmJiB3aW5kb3cuX19uYXYoJ2Rvd24n
KTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBpZiAoZS5rZXkgPT09ICdBcnJv
d1VwJykgewogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgIGUuc3RvcFBy
b3BhZ2F0aW9uKCk7CiAgICAgICAgICAgIHdpbmRvdy5fX25hdiAmJiB3aW5kb3cuX19uYXYoJ3VwJyk7
CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgaWYgKGUua2V5ID09PSAnRXNjYXBl
JykgewogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgIGUuc3RvcFByb3Bh
Z2F0aW9uKCk7CiAgICAgICAgICAgIC8vIEFsd2F5cyBkaXNtaXNzIHRoZSB3aG9sZSBwYW5lbCAobm90
IGp1c3QgdGhlIHNlYXJjaCBmaWVsZCkKICAgICAgICAgICAgaWYgKCFwaW5uZWRVSSkgYWhrKCdoaWRl
Jyk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24o
KTsKICAgIH0pOwogICAgc2Nsci5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAg
IGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgc3JjaC52YWx1ZSA9IHF1ZXJ5ID0gJyc7CiAgICAg
ICAgc2Nsci5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOwogICAgICAgIHNyY2guY2xhc3NMaXN0LnJlbW92
ZSgnaGFzLXZhbCcpOwogICAgICAgIHJlcXVlc3RWaWV3KCk7CiAgICAgICAgYWhrKCdmb2N1c1BhbmVs
Jyk7CiAgICAgICAgc3JjaC5mb2N1cygpOwogICAgfSk7CgogICAgY29uc3QgVEFCX05BTUVTID0geyBh
bGw6ICflhajpg6gnLCB0ZXh0OiAn5paH5pysJywgaW1hZ2U6ICflm77lg48nLCBmaWxlOiAn5paH5Lu2
JywgcGlubmVkOiAn5pS26JePJyB9OwogICAgY29uc3QgY2xyRGxnID0gZG9jdW1lbnQuZ2V0RWxlbWVu
dEJ5SWQoJ2Nsci1kbGcnKTsKICAgIGNvbnN0IGNsckFsbENiID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ2Nsci1hbGwnKTsKICAgIGZ1bmN0aW9uIG9wZW5DbGVhckRsZygpIHsKICAgICAgICBjb25zdCBu
YW1lID0gVEFCX05BTUVTW2N1clRhYl0gfHwgJ+W9k+WJjSc7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxl
bWVudEJ5SWQoJ2Nsci10aXRsZScpLnRleHRDb250ZW50ID0gJ+a4heepuuOAjCcgKyBuYW1lICsgJ+OA
je+8nyc7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Nsci1kZXNjJykudGV4dENvbnRl
bnQgPSBjdXJUYWIgPT09ICdwaW5uZWQnCiAgICAgICAgICAgID8gJ+m7mOiupOS7hea4heepuuW9k+Wk
qeeahOaUtuiXj+mhueOAguWLvumAieOAjOa4heepuuaJgOacieOAjeWPr+a4hemZpOivpemAiemhueWN
oeWFqOmDqOWGheWuueOAgicKICAgICAgICAgICAgOiAn5LuF5riF56m65b2T5YmN6YCJ6aG55Y2h44CC
6buY6K6k5Y+q5riF5b2T5aSp77yb5pS26JeP6aG55LiN5Lya6KKr5riF6Zmk44CC5Yu+6YCJ44CM5riF
56m65omA5pyJ44CN5Y+v5riF6Zmk6K+l6YCJ6aG55Y2h5YWo6YOo5pel5pyf44CCJzsKICAgICAgICBj
bHJBbGxDYi5jaGVja2VkID0gZmFsc2U7CiAgICAgICAgY2xyRGxnLmNsYXNzTGlzdC5hZGQoJ29uJyk7
CiAgICB9CiAgICBmdW5jdGlvbiBjbG9zZUNsZWFyRGxnKCkgewogICAgICAgIGNsckRsZy5jbGFzc0xp
c3QucmVtb3ZlKCdvbicpOwogICAgfQogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi1jbHIn
KS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9u
KCk7CiAgICAgICAgb3BlbkNsZWFyRGxnKCk7CiAgICB9KTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRC
eUlkKCdjbHItY2FuY2VsJykuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICBl
LnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgIGNsb3NlQ2xlYXJEbGcoKTsKICAgIH0pOwogICAgY2xy
RGxnLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgaWYgKGUudGFyZ2V0ID09
PSBjbHJEbGcpIGNsb3NlQ2xlYXJEbGcoKTsKICAgIH0pOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ2Nsci1vaycpLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgZS5zdG9w
UHJvcGFnYXRpb24oKTsKICAgICAgICBjb25zdCBzY29wZSA9IGNsckFsbENiLmNoZWNrZWQgPyAnYWxs
JyA6ICd0b2RheSc7CiAgICAgICAgY2xvc2VDbGVhckRsZygpOwogICAgICAgIGFoaygnY2xlYXInLCBj
dXJUYWIsIHNjb3BlKTsKICAgIH0pOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ211bHRpLWNu
dCcpLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRp
b24oKTsKICAgICAgICBjbGVhck11bHRpKHRydWUpOwogICAgfSk7CiAgICBkb2N1bWVudC5nZXRFbGVt
ZW50QnlJZCgnYnRuLXBpbicpLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAg
ZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICBwaW5uZWRVSSA9ICFwaW5uZWRVSTsKICAgICAgICBl
LmN1cnJlbnRUYXJnZXQuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCBwaW5uZWRVSSk7CiAgICAgICAgYWhr
KCd0b2dnbGVQaW4nLCBwaW5uZWRVSSA/ICcxJyA6ICcwJyk7CiAgICB9KTsKCiAgICB3aW5kb3cuX191
cGRhdGVDbGlwcyA9IHBheWxvYWQgPT4gewogICAgICAgIC8vIEtlZXAgcHJldmlvdXMgc2Nyb2xsIGZv
ciBsb2FkLW1vcmU7IHJlc2V0IHdoZW4gb3BlbmluZyBwYW5lbCB0byBmaXJzdCBpdGVtCiAgICAgICAg
Y29uc3Qga2VlcFNjcm9sbCA9ICFzZWxlY3RGaXJzdE9uU2hvdzsKICAgICAgICBjb25zdCBzdCA9IGxp
c3RFbC5zY3JvbGxUb3A7CiAgICAgICAgd2luZG93Ll9fd2FpdGluZ1ZpZXcgPSBmYWxzZTsKICAgICAg
ICBjb25zdCB3YXNBcHBlbmQgPSBwYXlsb2FkICYmIHBheWxvYWQuYXBwZW5kOwogICAgICAgIGxvYWRp
bmdNb3JlID0gZmFsc2U7CiAgICAgICAgY29uc3QgcHJldkl0ZW1zID0gYWxsQ2xpcHM7CiAgICAgICAg
bGV0IG5leHRJdGVtcyA9IFtdOwogICAgICAgIGxldCBuZXh0VG90YWwgPSAwOwogICAgICAgIGxldCBu
ZXh0RmlsdGVyZWQgPSBmYWxzZTsKICAgICAgICBsZXQgcFRhYiA9ICcnOwogICAgICAgIGxldCBwUGlu
bmVkVG90YWwgPSAtMTsKICAgICAgICBpZiAoQXJyYXkuaXNBcnJheShwYXlsb2FkKSkgewogICAgICAg
ICAgICBuZXh0SXRlbXMgPSBwYXlsb2FkOwogICAgICAgICAgICBuZXh0VG90YWwgPSBwYXlsb2FkLmxl
bmd0aDsKICAgICAgICAgICAgbmV4dEZpbHRlcmVkID0gZmFsc2U7CiAgICAgICAgfSBlbHNlIGlmIChw
YXlsb2FkICYmIHR5cGVvZiBwYXlsb2FkID09PSAnb2JqZWN0JykgewogICAgICAgICAgICBuZXh0VG90
YWwgPSBOdW1iZXIocGF5bG9hZC50b3RhbCkgfHwgMDsKICAgICAgICAgICAgbmV4dEl0ZW1zID0gQXJy
YXkuaXNBcnJheShwYXlsb2FkLml0ZW1zKSA/IHBheWxvYWQuaXRlbXMgOiBbXTsKICAgICAgICAgICAg
cFRhYiA9IHBheWxvYWQudGFiICE9IG51bGwgPyBTdHJpbmcocGF5bG9hZC50YWIpIDogJyc7CiAgICAg
ICAgICAgIGlmIChwYXlsb2FkLnBpbm5lZFRvdGFsICE9IG51bGwgJiYgcGF5bG9hZC5waW5uZWRUb3Rh
bCAhPT0gJycpCiAgICAgICAgICAgICAgICBwUGlubmVkVG90YWwgPSBOdW1iZXIocGF5bG9hZC5waW5u
ZWRUb3RhbCkgfHwgMDsKICAgICAgICAgICAgY29uc3QgcHEwID0gcGF5bG9hZC5xdWVyeSAhPSBudWxs
ID8gU3RyaW5nKHBheWxvYWQucXVlcnkpIDogJyc7CiAgICAgICAgICAgIG5leHRGaWx0ZXJlZCA9ICEh
KHBheWxvYWQuZmlsdGVyZWQgfHwgKHBxMCAmJiBwcTAudHJpbSgpKSk7CiAgICAgICAgICAgIGlmIChw
YXlsb2FkLmFwcGVuZCkgewogICAgICAgICAgICAgICAgLy8gQXBwZW5kIG9ubHkgYXBwbGllcyB0byB0
aGUgdGFiIHdlJ3JlIGN1cnJlbnRseSB2aWV3aW5nCiAgICAgICAgICAgICAgICBpZiAocFRhYiAmJiBw
VGFiICE9PSBjdXJUYWIpCiAgICAgICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICAgICAg
Y29uc3Qgc2VlbiA9IG5ldyBTZXQoYWxsQ2xpcHMubWFwKGMgPT4gK2MuaWQpKTsKICAgICAgICAgICAg
ICAgIGNvbnN0IG1lcmdlZCA9IGFsbENsaXBzLnNsaWNlKCk7CiAgICAgICAgICAgICAgICBuZXh0SXRl
bXMuZm9yRWFjaChpdCA9PiB7CiAgICAgICAgICAgICAgICAgICAgaWYgKCFzZWVuLmhhcygraXQuaWQp
KSBtZXJnZWQucHVzaChpdCk7CiAgICAgICAgICAgICAgICB9KTsKICAgICAgICAgICAgICAgIG5leHRJ
dGVtcyA9IG1lcmdlZDsKICAgICAgICAgICAgICAgIG5leHRUb3RhbCA9IE1hdGgubWF4KG5leHRUb3Rh
bCwgbmV4dEl0ZW1zLmxlbmd0aCk7CiAgICAgICAgICAgIH0KICAgICAgICAgICAgLy8g5pCc57Si5qGG
5Lul5omT5a2X6ZWc5YOP5Li65YeG77yM57ud5LiN6KKr5rue5ZCO55qE56OB55uY57uT5p6c5YaZ5Zue
5pen5YWz6ZSu5a2XCiAgICAgICAgICAgIHRyeSB7CiAgICAgICAgICAgICAgICBjb25zdCBzID0gZG9j
dW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaCcpOwogICAgICAgICAgICAgICAgaWYgKHMgJiYgU3Ry
aW5nKHMudmFsdWUgfHwgJycpLmxlbmd0aCkKICAgICAgICAgICAgICAgICAgICBxdWVyeSA9IHMudmFs
dWU7CiAgICAgICAgICAgICAgICBlbHNlIGlmIChwcTAgIT09ICcnICYmICFTdHJpbmcocXVlcnkgfHwg
JycpLnRyaW0oKSkKICAgICAgICAgICAgICAgICAgICBxdWVyeSA9IHBxMDsKICAgICAgICAgICAgfSBj
YXRjaCB7fQogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgIG5leHRJdGVtcyA9IFtdOwogICAgICAg
ICAgICBuZXh0VG90YWwgPSAwOwogICAgICAgICAgICBuZXh0RmlsdGVyZWQgPSBmYWxzZTsKICAgICAg
ICB9CgogICAgICAgIGNvbnN0IGJveFEgPSBTdHJpbmcocXVlcnkgfHwgJycpLnRyaW0oKTsKICAgICAg
ICBjb25zdCBwdXNoUSA9IChwYXlsb2FkICYmIHR5cGVvZiBwYXlsb2FkID09PSAnb2JqZWN0JyAmJiBw
YXlsb2FkLnF1ZXJ5ICE9IG51bGwpCiAgICAgICAgICAgID8gU3RyaW5nKHBheWxvYWQucXVlcnkpLnRy
aW0oKSA6ICcnOwoKICAgICAgICAvLyBBbHdheXMgcmVmcmVzaCDmlLbol48gYmFkZ2UgZnJvbSBob3N0
IHdoZW4gcHJvdmlkZWQKICAgICAgICBpZiAocFBpbm5lZFRvdGFsID49IDApCiAgICAgICAgICAgIHBp
bm5lZFRvdGFsID0gcFBpbm5lZFRvdGFsOwoKICAgICAgICAvLyBTdGFsZSBzZWFyY2ggcHVzaCAoZS5n
LiAic3F1YXJlIGxvZ2kiIGxhbmRzIGFmdGVyIHVzZXIgdHlwZWQgInNxdWFyZSBsb2dpbiIpIOKAlGNh
Y2hlIG9ubHkKICAgICAgICBpZiAoIXdhc0FwcGVuZCAmJiBuZXh0RmlsdGVyZWQgJiYgcHVzaFEgJiYg
Ym94USAmJiBwdXNoUSAhPT0gYm94USkgewogICAgICAgICAgICB2aWV3TWVtLnNldCh2aWV3TWVtS2V5
KHBUYWIgfHwgY3VyVGFiLCBwdXNoUSwgdG9kYXlPbmx5KSwgewogICAgICAgICAgICAgICAgaXRlbXM6
IG5leHRJdGVtcy5zbGljZSgpLAogICAgICAgICAgICAgICAgdG90YWw6IG5leHRUb3RhbAogICAgICAg
ICAgICB9KTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KCiAgICAgICAgLy8gU3RhbGUgcHVz
aCBmb3IgYW5vdGhlciB0YWI6IG9ubHkgcmVmcmVzaCB0aGF0IHRhYidzIHZpZXdNZW0sIGRvbid0IGhp
amFjayBVSQogICAgICAgIGlmICghd2FzQXBwZW5kICYmIHBUYWIgJiYgcFRhYiAhPT0gY3VyVGFiKSB7
CiAgICAgICAgICAgIGNvbnN0IG1lbVEgPSAocGF5bG9hZCAmJiB0eXBlb2YgcGF5bG9hZCA9PT0gJ29i
amVjdCcgJiYgcGF5bG9hZC5xdWVyeSAhPSBudWxsKQogICAgICAgICAgICAgICAgPyBTdHJpbmcocGF5
bG9hZC5xdWVyeSkgOiAnJzsKICAgICAgICAgICAgdmlld01lbS5zZXQodmlld01lbUtleShwVGFiLCBt
ZW1RLCB0b2RheU9ubHkpLCB7CiAgICAgICAgICAgICAgICBpdGVtczogbmV4dEl0ZW1zLnNsaWNlKCks
CiAgICAgICAgICAgICAgICB0b3RhbDogbmV4dFRvdGFsCiAgICAgICAgICAgIH0pOwogICAgICAgICAg
ICAvLyBTdGlsbCB1cGRhdGUgcGluIGJhZGdlIGlmIGhvc3Qgc2VudCBpdAogICAgICAgICAgICB0cnkg
ewogICAgICAgICAgICAgICAgY29uc3QgcGluQ250ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Bp
bi1jbnQnKTsKICAgICAgICAgICAgICAgIGlmIChwaW5DbnQgJiYgcGlubmVkVG90YWwgPiAwKSB7CiAg
ICAgICAgICAgICAgICAgICAgcGluQ250LnRleHRDb250ZW50ID0gcGlubmVkVG90YWw7CiAgICAgICAg
ICAgICAgICAgICAgcGluQ250LnN0eWxlLmRpc3BsYXkgPSAnJzsKICAgICAgICAgICAgICAgIH0KICAg
ICAgICAgICAgfSBjYXRjaCB7fQogICAgICAgICAgICAvLyBRUSDmkJzntKLmm77lm7rlrprmjqggYWxs
IHRhYiDihpIg5b2T5YmNIHRhYiDkvJrkuIDnm7TpqqjmnrbvvJvooaXkuIDmrKEgcmVxdWVzdFZpZXcK
ICAgICAgICAgICAgaWYgKHdhaXRpbmdEYXRhICYmIHB1c2hRID09PSBib3hRKSB7CiAgICAgICAgICAg
ICAgICBzZXRUaW1lb3V0KCgpID0+IHsKICAgICAgICAgICAgICAgICAgICBpZiAod2FpdGluZ0RhdGEg
JiYgY3VyVGFiICE9PSBwVGFiKQogICAgICAgICAgICAgICAgICAgICAgICByZXF1ZXN0VmlldygpOwog
ICAgICAgICAgICAgICAgfSwgNDApOwogICAgICAgICAgICB9CiAgICAgICAgICAgIHJldHVybjsKICAg
ICAgICB9CgogICAgICAgIC8vIEJvb3RzdHJhcCByYWNlOiBBSEsgcHVzaGVkIGVtcHR5IGJlZm9yZSBX
YXJtQWxsVmlld3Mg4oCUa2VlcCBza2VsZXRvbiwgaWdub3JlCiAgICAgICAgY29uc3QgcU9uID0gU3Ry
aW5nKHF1ZXJ5IHx8ICcnKS50cmltKCkubGVuZ3RoID4gMDsKICAgICAgICBpZiAoIXdhc0FwcGVuZCAm
JiAhbmV4dEl0ZW1zLmxlbmd0aCAmJiBuZXh0VG90YWwgPD0gMCAmJiAhcU9uICYmICFuZXh0RmlsdGVy
ZWQgJiYgIXNhd05vbkVtcHR5KSB7CiAgICAgICAgICAgIGlmICghd2luZG93Ll9fZW1wdHlGYWxsYmFj
a1QpIHsKICAgICAgICAgICAgICAgIHdpbmRvdy5fX2VtcHR5RmFsbGJhY2tUID0gc2V0VGltZW91dCgo
KSA9PiB7CiAgICAgICAgICAgICAgICAgICAgd2luZG93Ll9fZW1wdHlGYWxsYmFja1QgPSAwOwogICAg
ICAgICAgICAgICAgICAgIGlmIChzYXdOb25FbXB0eSkgcmV0dXJuOwogICAgICAgICAgICAgICAgICAg
IC8vIFRydWx5IGVtcHR5IGluc3RhbGwgYWZ0ZXIgd2FpdAogICAgICAgICAgICAgICAgICAgIHNhd05v
bkVtcHR5ID0gdHJ1ZTsKICAgICAgICAgICAgICAgICAgICBob3N0UHVzaGVkT25jZSA9IHRydWU7CiAg
ICAgICAgICAgICAgICAgICAgd2luZG93Ll9fZGF0YVJlYWR5ID0gdHJ1ZTsKICAgICAgICAgICAgICAg
ICAgICBhbGxDbGlwcyA9IFtdOwogICAgICAgICAgICAgICAgICAgIGRpc2tUb3RhbCA9IDA7CiAgICAg
ICAgICAgICAgICAgICAgY2xlYXJXYWl0aW5nRGF0YSgpOwogICAgICAgICAgICAgICAgICAgIHRyeSB7
IHJlbmRlcigpOyB9IGNhdGNoIHt9CiAgICAgICAgICAgICAgICB9LCA0NTAwKTsKICAgICAgICAgICAg
fQogICAgICAgICAgICB3YWl0aW5nRGF0YSA9IHRydWU7CiAgICAgICAgICAgIHdpbmRvdy5fX2RhdGFS
ZWFkeSA9IGZhbHNlOwogICAgICAgICAgICBob3N0UHVzaGVkT25jZSA9IGZhbHNlOwogICAgICAgICAg
ICBzZXRCb290TG9hZGluZyh0cnVlKTsKICAgICAgICAgICAgdHJ5IHsgcmVuZGVyKCk7IH0gY2F0Y2gg
e30KICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KCiAgICAgICAgY2xlYXJXYWl0aW5nRGF0YSgp
OwogICAgICAgIGFsbENsaXBzID0gbmV4dEl0ZW1zOwogICAgICAgIGRpc2tUb3RhbCA9IG5leHRUb3Rh
bDsKICAgICAgICAvLyBLZWVwIGJhciBjb25zaXN0ZW50IGlmIGxpc3QgZ3JldyBwYXN0IGEgc3RhbGUg
dG90YWwKICAgICAgICBpZiAoYWxsQ2xpcHMubGVuZ3RoID4gZGlza1RvdGFsKQogICAgICAgICAgICBk
aXNrVG90YWwgPSBhbGxDbGlwcy5sZW5ndGg7CiAgICAgICAgd2luZG93Ll9faG9zdEZpbHRlcmVkID0g
bmV4dEZpbHRlcmVkOwogICAgICAgIHdpbmRvdy5fX2hvc3RGaWx0ZXJRID0gKG5leHRGaWx0ZXJlZCAm
JiBwdXNoUSkgPyBwdXNoUSA6ICcnOwogICAgICAgIC8vIEZpbHRlcmVkIHNlYXJjaCB3aXRoIDAgaGl0
cyDigJRtdXN0IGxlYXZlIHNrZWxldG9uIChob3N0IGRpZCByZXNwb25kKQogICAgICAgIGlmICghd2Fz
QXBwZW5kICYmIG5leHRGaWx0ZXJlZCAmJiAhYWxsQ2xpcHMubGVuZ3RoICYmIGRpc2tUb3RhbCA8PSAw
KSB7CiAgICAgICAgICAgIGhvc3RQdXNoZWRPbmNlID0gdHJ1ZTsKICAgICAgICAgICAgc2F3Tm9uRW1w
dHkgPSB0cnVlOwogICAgICAgIH0KICAgICAgICBpZiAoYWxsQ2xpcHMubGVuZ3RoIHx8IGRpc2tUb3Rh
bCA+IDApCiAgICAgICAgICAgIHNhd05vbkVtcHR5ID0gdHJ1ZTsKICAgICAgICBpZiAod2luZG93Ll9f
ZW1wdHlGYWxsYmFja1QpIHsKICAgICAgICAgICAgY2xlYXJUaW1lb3V0KHdpbmRvdy5fX2VtcHR5RmFs
bGJhY2tUKTsKICAgICAgICAgICAgd2luZG93Ll9fZW1wdHlGYWxsYmFja1QgPSAwOwogICAgICAgIH0K
ICAgICAgICBpZiAoIXdhc0FwcGVuZCkgewogICAgICAgICAgICBjb25zdCBtZW1RID0gKHBheWxvYWQg
JiYgdHlwZW9mIHBheWxvYWQgPT09ICdvYmplY3QnICYmIHBheWxvYWQucXVlcnkgIT0gbnVsbCkKICAg
ICAgICAgICAgICAgID8gU3RyaW5nKHBheWxvYWQucXVlcnkpIDogcXVlcnk7CiAgICAgICAgICAgIHZp
ZXdNZW0uc2V0KHZpZXdNZW1LZXkoY3VyVGFiLCBtZW1RLCB0b2RheU9ubHkpLCB7CiAgICAgICAgICAg
ICAgICBpdGVtczogYWxsQ2xpcHMuc2xpY2UoKSwKICAgICAgICAgICAgICAgIHRvdGFsOiBkaXNrVG90
YWwKICAgICAgICAgICAgfSk7CiAgICAgICAgfQogICAgICAgIHdpbmRvdy5fX2RhdGFSZWFkeSA9IHRy
dWU7CiAgICAgICAgaG9zdFB1c2hlZE9uY2UgPSB0cnVlOwogICAgICAgIGNvbnN0IHdhc0Jvb3RMb2Fk
aW5nID0gYm9vdExvYWRpbmc7CiAgICAgICAgbGV0IHNhbWVQYWludCA9IGZhbHNlOwogICAgICAgIGlm
ICghd2FzQXBwZW5kICYmICF3YXNCb290TG9hZGluZyAmJiBwcmV2SXRlbXMgJiYgcHJldkl0ZW1zLmxl
bmd0aCA9PT0gYWxsQ2xpcHMubGVuZ3RoICYmIHByZXZJdGVtcy5sZW5ndGgpIHsKICAgICAgICAgICAg
c2FtZVBhaW50ID0gdHJ1ZTsKICAgICAgICAgICAgZm9yIChsZXQgaSA9IDA7IGkgPCBhbGxDbGlwcy5s
ZW5ndGg7IGkrKykgewogICAgICAgICAgICAgICAgaWYgKCtwcmV2SXRlbXNbaV0uaWQgIT09ICthbGxD
bGlwc1tpXS5pZCkgeyBzYW1lUGFpbnQgPSBmYWxzZTsgYnJlYWs7IH0KICAgICAgICAgICAgfQogICAg
ICAgICAgICBpZiAoc2FtZVBhaW50ICYmICFsaXN0RWwucXVlcnlTZWxlY3RvcignLml0bScpKSBzYW1l
UGFpbnQgPSBmYWxzZTsKICAgICAgICB9CiAgICAgICAgY29uc3QgZmluaXNoVXBkYXRlID0gKCkgPT4g
ewogICAgICAgICAgICBjbGVhcldhaXRpbmdEYXRhKCk7CiAgICAgICAgICAgIGlmICghc2FtZVBhaW50
KSB7CiAgICAgICAgICAgICAgICByZW5kZXIoKTsKICAgICAgICAgICAgICAgIGFwcGx5VGFiU3dpdGNo
QW5pbSgpOwogICAgICAgICAgICB9IGVsc2UgewogICAgICAgICAgICAgICAgLy8gc2FtZSBpZHMg4oCU
c3RpbGwgcmVmcmVzaCBjb3VudHMgKHBpbm5lZFRvdGFsIC8gZGlza1RvdGFsIG1heSBoYXZlIGNoYW5n
ZWQpCiAgICAgICAgICAgICAgICB0cnkgewogICAgICAgICAgICAgICAgICAgIGNvbnN0IHBpbkNudCA9
IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwaW4tY250Jyk7CiAgICAgICAgICAgICAgICAgICAgaWYg
KHBpbkNudCkgewogICAgICAgICAgICAgICAgICAgICAgICBjb25zdCBuID0gTnVtYmVyKHBpbm5lZFRv
dGFsKSB8fCAoY3VyVGFiID09PSAncGlubmVkJyA/IGRpc2tUb3RhbCA6IDApOwogICAgICAgICAgICAg
ICAgICAgICAgICBpZiAobiA+IDApIHsKICAgICAgICAgICAgICAgICAgICAgICAgICAgIHBpbkNudC50
ZXh0Q29udGVudCA9IG47CiAgICAgICAgICAgICAgICAgICAgICAgICAgICBwaW5DbnQuc3R5bGUuZGlz
cGxheSA9ICcnOwogICAgICAgICAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICAgICAgfQog
ICAgICAgICAgICAgICAgICAgIGNvbnN0IGxvYWRlZCA9IGFsbENsaXBzLmxlbmd0aDsKICAgICAgICAg
ICAgICAgICAgICBsZXQgc2hvd1RvdGFsID0gZGlza1RvdGFsID4gMCA/IGRpc2tUb3RhbCA6IGxvYWRl
ZDsKICAgICAgICAgICAgICAgICAgICBpZiAoY3VyVGFiID09PSAncGlubmVkJyAmJiBwaW5uZWRUb3Rh
bCA+IHNob3dUb3RhbCkKICAgICAgICAgICAgICAgICAgICAgICAgc2hvd1RvdGFsID0gcGlubmVkVG90
YWw7CiAgICAgICAgICAgICAgICAgICAgY29uc3QgcU9uMiA9IFN0cmluZyhxdWVyeSB8fCAnJykudHJp
bSgpLmxlbmd0aCA+IDA7CiAgICAgICAgICAgICAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQo
J2Jhci10eHQnKS50ZXh0Q29udGVudCA9IHFPbjIKICAgICAgICAgICAgICAgICAgICAgICAgPyAobG9h
ZGVkICsgJyDmnaEnKQogICAgICAgICAgICAgICAgICAgICAgICA6IChzaG93VG90YWwgPiBsb2FkZWQg
PyAobG9hZGVkICsgJyAvICcgKyBzaG93VG90YWwgKyAnIOadoScpIDogKHNob3dUb3RhbCArICcg5p2h
JykpOwogICAgICAgICAgICAgICAgfSBjYXRjaCB7fQogICAgICAgICAgICB9CiAgICAgICAgICAgIGlm
IChrZWVwU2Nyb2xsKQogICAgICAgICAgICAgICAgbGlzdEVsLnNjcm9sbFRvcCA9IHN0OwogICAgICAg
ICAgICBlbHNlIGlmICghc2FtZVBhaW50KQogICAgICAgICAgICAgICAgbGlzdEVsLnNjcm9sbFRvcCA9
IDA7CiAgICAgICAgfTsKICAgICAgICBpZiAod2FzQm9vdExvYWRpbmcpIHsKICAgICAgICAgICAgY29u
c3Qgc2luY2UgPSB3aW5kb3cuX19za2VsU2luY2UgfHwgMDsKICAgICAgICAgICAgY29uc3Qgd2FpdCA9
IHNpbmNlID8gTWF0aC5tYXgoMCwgODAgLSAoRGF0ZS5ub3coKSAtIHNpbmNlKSkgOiAwOwogICAgICAg
ICAgICBpZiAod2FpdCA+IDApCiAgICAgICAgICAgICAgICBzZXRUaW1lb3V0KGZpbmlzaFVwZGF0ZSwg
d2FpdCk7CiAgICAgICAgICAgIGVsc2UKICAgICAgICAgICAgICAgIGZpbmlzaFVwZGF0ZSgpOwogICAg
ICAgIH0gZWxzZSB7CiAgICAgICAgICAgIGZpbmlzaFVwZGF0ZSgpOwogICAgICAgIH0KICAgIH07CiAg
ICB3aW5kb3cuX19zZXRQaW5uZWQgPSB2ID0+IHsKICAgICAgICBwaW5uZWRVSSA9ICEhdjsKICAgICAg
ICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLXBpbicpLmNsYXNzTGlzdC50b2dnbGUoJ29uJywg
cGlubmVkVUkpOwogICAgfTsKICAgIHdpbmRvdy5fX2xvYWRNb3JlRG9uZSA9ICgpID0+IHsKICAgICAg
ICBsb2FkaW5nTW9yZSA9IGZhbHNlOwogICAgfTsKCiAgICBzY2hlZHVsZURlbGF5ZWRTa2VsKCk7CiAg
ICByZXF1ZXN0VmlldygpOwogICAgLy8gc2NoZWR1bGVEZWxheWVkU2tlbCBhbHJlYWR5IHJlbmRlcigp
J2Qgd2hlbiBlbXB0eTsgc3RpbGwgcGFpbnQgb25jZSBmb3IgY2hyb21lCgogICAgPC9zY3JpcHQ+Cjwv
Ym9keT4KPC9odG1sPg==
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
    pasteMany(ids) {
        RequestPasteMany(ids)
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
            ; Don't wait for coalesced PushClips —fill the blank placeholder now
            if item.HasProp("imgFile") && item.imgFile != ""
                SetTimer(InjectStoreThumbNow.Bind(Integer(item.uid), String(item.imgFile)), -10)
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
