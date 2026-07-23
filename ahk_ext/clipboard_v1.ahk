#Requires AutoHotkey v2.0
#NoTrayIcon
#Include %A_Temp%\WebView2.ahk
#SingleInstance Force
#UseHook
Persistent


GetCaretPosEx(&left?, &top?, &right?, &bottom?, useHook := false, skipHeavy := false, preferUIA := false) {
    if getCaretPosFromGui(&hwnd := 0)
        return true
    ; Acc/UIA from #UseHook hotkeys can deadlock OneNote / some Office hosts
    if skipHeavy
        return false
    try
        className := WinGetClass(hwnd)
    catch
        className := ""
    ; preferUIA is unused for OneNote now 鈥?callers skipHeavy instead (UIA crashes OneNote)
    if className ~= "^(?:Windows|Microsoft)\.UI\..+"
        funcs := [getCaretPosFromUIA, getCaretPosFromHook, getCaretPosFromMSAA]
    else if className ~= "^HwndWrapper\[PowerShell_ISE\.exe;;[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\]"
        funcs := [getCaretPosFromHook, getCaretPosFromWpfCaret]
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
            if hwnd := NumGet(guiThreadInfo, x64 ? 48 : 28, "ptr") {
                getRect(guiThreadInfo.Ptr + (x64 ? 56 : 32), &left, &top, &right, &bottom)
                scaleRect(getWindowScale(hwnd), &left, &top, &right, &bottom)
                clientToScreenRect(hwnd, &left, &top, &right, &bottom)
                return true
            }
            hwnd := NumGet(guiThreadInfo, x64 ? 16 : 12, "ptr")
        }
        return false
    }

    getCaretPosFromMSAA() {
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
                pt := x | y << 32
                DllCall("ScreenToClient", "ptr", hwnd, "int64*", &pt)
                left := pt & 0xffffffff
                top := pt >> 32
                right := left + w
                bottom := top + h
                scaleRect(getWindowScale(hwnd), &left, &top, &right, &bottom)
                clientToScreenRect(hwnd, &left, &top, &right, &bottom)
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
            ; Only Character unit 鈥?Line expand was too aggressive on scroll.
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
            ; SMTO_ABORTIFHUNG 鈥?don't freeze if target ignores WM_IME_COMPOSITION
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

; 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
;  Config
; 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
; 闈㈡澘瀹介珮锛堝熀鍑嗗儚绱狅紝鍙洿鎺ユ敼锛涘疄闄呭昂瀵镐細鎸夊睆骞曢珮搴﹀井璋冿級
UI_W := 360
UI_H := 425   ; 鍘?485锛屽噺 60
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

; HELPME_HOME set 鈫?%HELPME_HOME%\command_ext\ahk_ext\ahk\clip_v1
; otherwise 鈫?%A_ScriptDir%\ahk\clip_v1
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

; 鈹€鈹€ Crash diagnostics: last line in debug.log 鈮?where it died 鈹€鈹€
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

; 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
;  鍐呭祵 HTML锛坆acktick 宸茶浆涔変负 ``锛?
; 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
HTML_B64 := "
(
PCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9InpoLUNOIj4KPGhlYWQ+CiAgICA8
bWV0YSBjaGFyc2V0PSJVVEYtOCI+CiAgICA8dGl0bGU+5Ymq6LS05p2/PC90aXRs
ZT4KICAgIDxzdHlsZT4KICAgICAgICA6cm9vdCB7CiAgICAgICAgICAgIC0tYmc6
ICAgICAjZWVmMWY2OwogICAgICAgICAgICAtLWFjYzogICAgIzViNzNlODsKICAg
ICAgICAgICAgLS10eHQ6ICAgICMyYzJlMzY7CiAgICAgICAgICAgIC0tdHh0Mjog
ICAjNmI3MDgwOwogICAgICAgICAgICAtLXR4dDM6ICAgIzlhYTBiMDsKICAgICAg
ICAgICAgLS1jYXJkOiAgICNmZmZmZmY7CiAgICAgICAgICAgIC0tY2FyZC1oOiAj
ZjhmOWZjOwogICAgICAgICAgICAtLXI6ICAgICAgNHB4OwogICAgICAgICAgICAt
LXRyOiAgICAgMC4xMnMgZWFzZTsKICAgICAgICB9CiAgICAgICAgKiwgKjo6YmVm
b3JlLCAqOjphZnRlciB7IGJveC1zaXppbmc6IGJvcmRlci1ib3g7IG1hcmdpbjog
MDsgcGFkZGluZzogMDsgfQogICAgICAgIGh0bWwsIGJvZHkgewogICAgICAgICAg
ICB3aWR0aDogMTAwJTsgaGVpZ2h0OiAxMDAlOyBvdmVyZmxvdzogaGlkZGVuOwog
ICAgICAgICAgICBiYWNrZ3JvdW5kOiB2YXIoLS1iZyk7IGNvbG9yOiB2YXIoLS10
eHQpOwogICAgICAgICAgICBmb250OiAxMnB4LzEuNDUgJ1NlZ29lIFVJJywnTWlj
cm9zb2Z0IFlhSGVpIFVJJyxzeXN0ZW0tdWksc2Fucy1zZXJpZjsKICAgICAgICAg
ICAgdXNlci1zZWxlY3Q6IG5vbmU7CiAgICAgICAgfQogICAgICAgIDo6LXdlYmtp
dC1zY3JvbGxiYXIgeyB3aWR0aDogNHB4OyB9CiAgICAgICAgOjotd2Via2l0LXNj
cm9sbGJhci10aHVtYiB7IGJhY2tncm91bmQ6ICNkMGQzZGM7IGJvcmRlci1yYWRp
dXM6IDJweDsgfQoKICAgICAgICAjYXBwIHsKICAgICAgICAgICAgaGVpZ2h0OiAx
MDAlOyBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOwogICAg
ICAgICAgICBiYWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGllbnQoMTgwZGVnLCAjZjdm
OWZjIDAlLCAjZWVmMWY2IDEwMCUpOwogICAgICAgICAgICAtd2Via2l0LWFwcC1y
ZWdpb246IGRyYWc7IGFwcC1yZWdpb246IGRyYWc7CiAgICAgICAgICAgIHBvc2l0
aW9uOiByZWxhdGl2ZTsKICAgICAgICAgICAgb3ZlcmZsb3c6IGhpZGRlbjsKICAg
ICAgICB9CgogICAgICAgIC8qIE5pZ2h0IGFtYmllbmNlOiBzdGFycyArIG1vb24g
Ki8KICAgICAgICAjd3gtc3RhcnMgewogICAgICAgICAgICBwb3NpdGlvbjogYWJz
b2x1dGU7IGluc2V0OiAwOyB6LWluZGV4OiAzNTsKICAgICAgICAgICAgcG9pbnRl
ci1ldmVudHM6IG5vbmU7IG9wYWNpdHk6IDA7CiAgICAgICAgICAgIHRyYW5zaXRp
b246IG9wYWNpdHkgLjlzIGVhc2U7CiAgICAgICAgICAgIG92ZXJmbG93OiBoaWRk
ZW47CiAgICAgICAgfQogICAgICAgICN3eC1zdGFycy5vbiB7IG9wYWNpdHk6IDE7
IH0KICAgICAgICAud3gtc3RhciB7CiAgICAgICAgICAgIHBvc2l0aW9uOiBhYnNv
bHV0ZTsgd2lkdGg6IDJweDsgaGVpZ2h0OiAycHg7IGJvcmRlci1yYWRpdXM6IDUw
JTsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2ZmZjsKICAgICAgICAgICAgYm94
LXNoYWRvdzogMCAwIDRweCByZ2JhKDI1NSwyNTUsMjU1LC45KTsKICAgICAgICAg
ICAgYW5pbWF0aW9uOiB3eFR3aW5rbGUgMi44cyBlYXNlLWluLW91dCBpbmZpbml0
ZTsKICAgICAgICB9CiAgICAgICAgLnd4LXN0YXIuYmlnIHsKICAgICAgICAgICAg
d2lkdGg6IDNweDsgaGVpZ2h0OiAzcHg7CiAgICAgICAgICAgIGJveC1zaGFkb3c6
IDAgMCA2cHggcmdiYSgyNTUsMjU1LDI1NSwxKSwgMCAwIDEycHggcmdiYSgxODAs
MjAwLDI1NSwuNik7CiAgICAgICAgfQogICAgICAgIEBrZXlmcmFtZXMgd3hUd2lu
a2xlIHsKICAgICAgICAgICAgMCUsIDEwMCUgeyBvcGFjaXR5OiAuMzU7IHRyYW5z
Zm9ybTogc2NhbGUoLjg1KTsgfQogICAgICAgICAgICA1MCUgeyBvcGFjaXR5OiAx
OyB0cmFuc2Zvcm06IHNjYWxlKDEuMTUpOyB9CiAgICAgICAgfQoKICAgICAgICAj
d3gtbW9vbiB7CiAgICAgICAgICAgIHBvc2l0aW9uOiBhYnNvbHV0ZTsKICAgICAg
ICAgICAgdG9wOiAyNHB4OwogICAgICAgICAgICByaWdodDogMTZweDsKICAgICAg
ICAgICAgei1pbmRleDogNDA7CiAgICAgICAgICAgIHBvaW50ZXItZXZlbnRzOiBu
b25lOwogICAgICAgICAgICBmb250LXNpemU6IDIxcHg7CiAgICAgICAgICAgIGxp
bmUtaGVpZ2h0OiAxOwogICAgICAgICAgICBvcGFjaXR5OiAwOwogICAgICAgICAg
ICB0cmFuc2Zvcm06IHRyYW5zbGF0ZTNkKDAsIDZweCwgMCkgc2NhbGUoLjkyKTsK
ICAgICAgICAgICAgdHJhbnNpdGlvbjogb3BhY2l0eSAuN3MgZWFzZSwgdHJhbnNm
b3JtIC43cyBlYXNlOwogICAgICAgICAgICBmaWx0ZXI6IGRyb3Atc2hhZG93KDAg
MCA4cHggcmdiYSgyMDAsIDIxNSwgMjU1LCAuNSkpOwogICAgICAgICAgICB1c2Vy
LXNlbGVjdDogbm9uZTsKICAgICAgICB9CiAgICAgICAgI3d4LW1vb24ub24gewog
ICAgICAgICAgICBvcGFjaXR5OiAxOwogICAgICAgICAgICB0cmFuc2Zvcm06IHRy
YW5zbGF0ZTNkKDAsIDAsIDApIHNjYWxlKDEpOwogICAgICAgICAgICBhbmltYXRp
b246IHd4TW9vbkZsb2F0IDZzIGVhc2UtaW4tb3V0IGluZmluaXRlOwogICAgICAg
IH0KICAgICAgICBAa2V5ZnJhbWVzIHd4TW9vbkZsb2F0IHsKICAgICAgICAgICAg
MCUsIDEwMCUgeyB0cmFuc2Zvcm06IHRyYW5zbGF0ZTNkKDAsIDAsIDApOyB9CiAg
ICAgICAgICAgIDUwJSB7IHRyYW5zZm9ybTogdHJhbnNsYXRlM2QoMCwgLTNweCwg
MCk7IH0KICAgICAgICB9CgogICAgICAgIC8qIE5pZ2h0IG1vZGUg4oCUIHdob2xl
IHBhbmVsIHRoZW1lICovCiAgICAgICAgI2FwcC53eC1uaWdodCB7CiAgICAgICAg
ICAgIC0tYmc6ICMxNDE4MjQ7CiAgICAgICAgICAgIC0tdHh0OiAjZThlYWYyOwog
ICAgICAgICAgICAtLXR4dDI6ICNhN2FkYmY7CiAgICAgICAgICAgIC0tdHh0Mzog
IzdkODQ5OTsKICAgICAgICAgICAgLS1jYXJkOiAjMWUyNDM2OwogICAgICAgICAg
ICAtLWNhcmQtaDogIzI2MmQ0MjsKICAgICAgICAgICAgLS1hY2M6ICM3YjhmZmY7
CiAgICAgICAgICAgIGJhY2tncm91bmQ6IGxpbmVhci1ncmFkaWVudCgxODBkZWcs
ICMxYTIwMzMgMCUsICMxMjE2MWYgMTAwJSk7CiAgICAgICAgfQogICAgICAgICNh
cHAud3gtbmlnaHQgI2hkciB7IGJhY2tncm91bmQ6IHJnYmEoMjQsIDI4LCA0Miwg
LjkyKTsgfQogICAgICAgICNhcHAud3gtbmlnaHQgI3RhYnMgeyBiYWNrZ3JvdW5k
OiByZ2JhKDIwLCAyNCwgMzYsIC45KTsgfQogICAgICAgICNhcHAud3gtbmlnaHQg
I3NlYXJjaC1ib3ggeyBiYWNrZ3JvdW5kOiByZ2JhKDI4LCAzNCwgNTAsIC45NSk7
IGJvcmRlcjogMXB4IHNvbGlkIHJnYmEoMjU1LDI1NSwyNTUsLjA2KTsgfQogICAg
ICAgICNhcHAud3gtbmlnaHQgLnRhYi5vbiB7CiAgICAgICAgICAgIGJhY2tncm91
bmQ6IHJnYmEoNDAsIDQ4LCA3MiwgLjk1KTsgY29sb3I6IHZhcigtLWFjYyk7CiAg
ICAgICAgICAgIGJveC1zaGFkb3c6IDAgMXB4IDNweCByZ2JhKDAsMCwwLC4yNSk7
CiAgICAgICAgfQogICAgICAgICNhcHAud3gtbmlnaHQgLml0bSB7CiAgICAgICAg
ICAgIGJhY2tncm91bmQ6IHZhcigtLWNhcmQpOwogICAgICAgICAgICBib3gtc2hh
ZG93OiAwIDFweCA0cHggcmdiYSgwLDAsMCwuMjgpOwogICAgICAgIH0KICAgICAg
ICAjYXBwLnd4LW5pZ2h0IC5pdG06aG92ZXIgeyBiYWNrZ3JvdW5kOiB2YXIoLS1j
YXJkLWgpOyB9CiAgICAgICAgI2FwcC53eC1uaWdodCAuaXRtLnNlbCB7CiAgICAg
ICAgICAgIGJhY2tncm91bmQ6ICMyYTNhNjg7CiAgICAgICAgICAgIGJveC1zaGFk
b3c6IDAgMCAwIDJweCByZ2JhKDE0MCwgMTY1LCAyNTUsIC43NSksIDAgMnB4IDEw
cHggcmdiYSg5MCwgMTIwLCAyNTUsIC4zNSk7CiAgICAgICAgfQogICAgICAgICNh
cHAud3gtbmlnaHQgLml0bS5tdWx0aSB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6
ICMzMTQyNzg7CiAgICAgICAgICAgIGJveC1zaGFkb3c6IDAgMCAwIDJweCByZ2Jh
KDE1MCwgMTc1LCAyNTUsIC44NSksIDAgMnB4IDEwcHggcmdiYSg5MCwgMTIwLCAy
NTUsIC40KTsKICAgICAgICB9CiAgICAgICAgI2FwcC53eC1uaWdodCAuaXRtLm11
bHRpLnNlbCB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICMzYTRmOGM7CiAgICAg
ICAgICAgIGJveC1zaGFkb3c6IDAgMCAwIDIuNXB4IHJnYmEoMTc1LCAxOTUsIDI1
NSwgLjk1KSwgMCAzcHggMTJweCByZ2JhKDEwMCwgMTMwLCAyNTUsIC41KTsKICAg
ICAgICB9CiAgICAgICAgI2FwcC53eC1uaWdodCAjYnRuLXRvcCB7IGJhY2tncm91
bmQ6ICMyYTMxNDg7IGNvbG9yOiB2YXIoLS10eHQyKTsgfQogICAgICAgICNhcHAu
d3gtbmlnaHQgOjotd2Via2l0LXNjcm9sbGJhci10aHVtYiB7IGJhY2tncm91bmQ6
ICMzYTQyNTg7IH0KICAgICAgICAvKiDilIDilIAgUm93IDEg4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSAICovCiAgICAgICAgI2hkciB7CiAgICAgICAgICAgIGRpc3BsYXk6
IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGZsZXgtc2hyaW5rOiAwOwogICAg
ICAgICAgICBwYWRkaW5nOiA1cHggNnB4IDVweCA4cHg7IGdhcDogNHB4OwogICAg
ICAgICAgICBiYWNrZ3JvdW5kOiAjZjRmNmZiOwogICAgICAgIH0KICAgICAgICAj
aGVhcnQgeyBmbGV4LXNocmluazogMDsgbGluZS1oZWlnaHQ6IDE7IGRpc3BsYXk6
ZmxleDsgYWxpZ24taXRlbXM6Y2VudGVyOyB9CiAgICAgICAgI2hlYXJ0IHN2ZyB7
IHdpZHRoOjE3cHg7IGhlaWdodDoxN3B4OyBjb2xvcjogdmFyKC0tdHh0Mik7IH0K
ICAgICAgICAjaGRyLWdyb3cgeyBmbGV4OiAxOyBtaW4td2lkdGg6IDhweDsgfQoK
ICAgICAgICAvKiBTZWFyY2g6IG92ZXJsYXkgZXhwYW5kICh0cmFuc2Zvcm0vb3Bh
Y2l0eSBvbmx5IOKAlCBubyB3aWR0aCBsYXlvdXQgdGhyYXNoKSAqLwogICAgICAg
ICNzZWFyY2gtd3JhcCB7CiAgICAgICAgICAgIGZsZXg6IDAgMCAyOHB4OwogICAg
ICAgICAgICB3aWR0aDogMjhweDsKICAgICAgICAgICAgaGVpZ2h0OiAyOHB4Owog
ICAgICAgICAgICBwb3NpdGlvbjogcmVsYXRpdmU7CiAgICAgICAgICAgIHotaW5k
ZXg6IDY7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsg
YXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICB9CiAgICAgICAgI2J0bi1zZWFy
Y2ggewogICAgICAgICAgICBwb3NpdGlvbjogYWJzb2x1dGU7IHJpZ2h0OiAwOyB0
b3A6IDA7CiAgICAgICAgICAgIHdpZHRoOiAyOHB4OyBoZWlnaHQ6IDI4cHg7CiAg
ICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1
c3RpZnktY29udGVudDogY2VudGVyOwogICAgICAgICAgICBib3JkZXI6IG5vbmU7
IGJhY2tncm91bmQ6IG5vbmU7IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICAgICAg
Y29sb3I6IHZhcigtLXR4dDMpOyBib3JkZXItcmFkaXVzOiB2YXIoLS1yKTsKICAg
ICAgICAgICAgei1pbmRleDogMjsKICAgICAgICAgICAgdHJhbnNpdGlvbjogY29s
b3IgMC4xNXMgZWFzZSwgYmFja2dyb3VuZCAwLjE1cyBlYXNlLCBvcGFjaXR5IDAu
MTVzIGVhc2U7CiAgICAgICAgfQogICAgICAgICNidG4tc2VhcmNoOmhvdmVyIHsg
Y29sb3I6IHZhcigtLWFjYyk7IGJhY2tncm91bmQ6IHJnYmEoOTEsMTE1LDIzMiwu
MSk7IH0KICAgICAgICAjYnRuLXNlYXJjaCBzdmcgeyB3aWR0aDogMTVweDsgaGVp
Z2h0OiAxNXB4OyBkaXNwbGF5OiBibG9jazsgfQogICAgICAgICNzZWFyY2gtd3Jh
cC5vcGVuICNidG4tc2VhcmNoIHsKICAgICAgICAgICAgb3BhY2l0eTogMDsKICAg
ICAgICAgICAgcG9pbnRlci1ldmVudHM6IG5vbmU7CiAgICAgICAgfQoKICAgICAg
ICAjc2VhcmNoLWJveCB7CiAgICAgICAgICAgIHBvc2l0aW9uOiBhYnNvbHV0ZTsK
ICAgICAgICAgICAgcmlnaHQ6IDA7CiAgICAgICAgICAgIHRvcDogMDsKICAgICAg
ICAgICAgd2lkdGg6IDE5NnB4OwogICAgICAgICAgICBoZWlnaHQ6IDI4cHg7CiAg
ICAgICAgICAgIGJveC1zaXppbmc6IGJvcmRlci1ib3g7CiAgICAgICAgICAgIHBh
ZGRpbmc6IDAgMnB4IDAgNHB4OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZjRm
NmZiOwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiB2YXIoLS1yKTsKICAgICAg
ICAgICAgb3BhY2l0eTogMDsKICAgICAgICAgICAgdHJhbnNmb3JtOiB0cmFuc2xh
dGUzZCg4cHgsIDAsIDApOwogICAgICAgICAgICBwb2ludGVyLWV2ZW50czogbm9u
ZTsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsKICAgICAgICAgICAgYWxpZ24t
aXRlbXM6IGNlbnRlcjsKICAgICAgICAgICAgZ2FwOiA0cHg7CiAgICAgICAgICAg
IHdpbGwtY2hhbmdlOiB0cmFuc2Zvcm0sIG9wYWNpdHk7CiAgICAgICAgICAgIGJh
Y2tmYWNlLXZpc2liaWxpdHk6IGhpZGRlbjsKICAgICAgICAgICAgdHJhbnNpdGlv
bjogb3BhY2l0eSAwLjE2cyBlYXNlLCB0cmFuc2Zvcm0gMC4ycyBjdWJpYy1iZXpp
ZXIoMC4yMiwgMSwgMC4zNiwgMSk7CiAgICAgICAgfQogICAgICAgICNzZWFyY2gt
d3JhcC5vcGVuICNzZWFyY2gtYm94IHsKICAgICAgICAgICAgb3BhY2l0eTogMTsK
ICAgICAgICAgICAgdHJhbnNmb3JtOiB0cmFuc2xhdGUzZCgwLCAwLCAwKTsKICAg
ICAgICAgICAgcG9pbnRlci1ldmVudHM6IGF1dG87CiAgICAgICAgfQoKICAgICAg
ICAjc2VhcmNoIHsKICAgICAgICAgICAgZmxleDogMTsgbWluLXdpZHRoOiAwOyBo
ZWlnaHQ6IDI4cHg7IGJvcmRlcjogbm9uZTsKICAgICAgICAgICAgYm9yZGVyLWJv
dHRvbTogMXB4IHNvbGlkIHRyYW5zcGFyZW50OwogICAgICAgICAgICBib3JkZXIt
cmFkaXVzOiAwOyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsgY29sb3I6IHZhcigt
LXR4dCk7IGZvbnQtc2l6ZTogMTJweDsKICAgICAgICAgICAgcGFkZGluZzogMCAy
MnB4IDAgMnB4OyBvdXRsaW5lOiBub25lOwogICAgICAgICAgICB0cmFuc2l0aW9u
OiBib3JkZXItYm90dG9tLWNvbG9yIDAuMTVzIGVhc2U7CiAgICAgICAgfQogICAg
ICAgICNzZWFyY2gtd3JhcC5vcGVuICNzZWFyY2g6Zm9jdXMgewogICAgICAgICAg
ICBib3JkZXItYm90dG9tLWNvbG9yOiB2YXIoLS1hY2MpOwogICAgICAgIH0KICAg
ICAgICAjc2VhcmNoLXdyYXAub3BlbiAjc2VhcmNoLmhhcy12YWw6bm90KDpmb2N1
cykgewogICAgICAgICAgICBib3JkZXItYm90dG9tLWNvbG9yOiAjYzVjYWQ2Owog
ICAgICAgIH0KICAgICAgICAjc2VhcmNoOjpwbGFjZWhvbGRlciB7IGNvbG9yOiB2
YXIoLS10eHQzKTsgfQogICAgICAgICNzZWFyY2gtY2xyIHsKICAgICAgICAgICAg
cG9zaXRpb246IGFic29sdXRlOyByaWdodDogNHB4OyB0b3A6IDUwJTsgdHJhbnNm
b3JtOiB0cmFuc2xhdGVZKC01MCUpOwogICAgICAgICAgICBib3JkZXI6IG5vbmU7
IGJhY2tncm91bmQ6IG5vbmU7IGNvbG9yOiB2YXIoLS10eHQzKTsgY3Vyc29yOiBw
b2ludGVyOwogICAgICAgICAgICBmb250LXNpemU6IDExcHg7IGRpc3BsYXk6IG5v
bmU7IHBhZGRpbmc6IDJweDsKICAgICAgICAgICAgb3BhY2l0eTogMC44NTsKICAg
ICAgICAgICAgdHJhbnNpdGlvbjogY29sb3IgMC4xMnMgZWFzZSwgb3BhY2l0eSAw
LjEycyBlYXNlOwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRy
YWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgfQogICAgICAgICNzZWFy
Y2gtY2xyOmhvdmVyIHsgY29sb3I6IHZhcigtLWFjYyk7IG9wYWNpdHk6IDE7IH0K
CiAgICAgICAgI2J0bi10b2RheSB7CiAgICAgICAgICAgIGRpc3BsYXk6IG5vbmU7
CiAgICAgICAgICAgIGhlaWdodDogMThweDsgcGFkZGluZzogMCA3cHg7IGZsZXgt
c2hyaW5rOiAwOwogICAgICAgICAgICBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0
aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAgICAgICAgICAgYm9yZGVyOiAxcHggc29s
aWQgcmdiYSg5MSwxMTUsMjMyLC4yMik7IGJhY2tncm91bmQ6IHJnYmEoOTEsMTE1
LDIzMiwuMTApOwogICAgICAgICAgICBjb2xvcjogIzZiODJlODsgYm9yZGVyLXJh
ZGl1czogOTk5cHg7IGZvbnQtc2l6ZTogOXB4OyBmb250LXdlaWdodDogNjAwOwog
ICAgICAgICAgICBsaW5lLWhlaWdodDogMTsgd2hpdGUtc3BhY2U6IG5vd3JhcDsg
Y3Vyc29yOiBwb2ludGVyOwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246
IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgICAgIHRyYW5z
aXRpb246IGNvbG9yIHZhcigtLXRyKSwgYmFja2dyb3VuZCB2YXIoLS10ciksIGJv
cmRlci1jb2xvciB2YXIoLS10ciksIG9wYWNpdHkgdmFyKC0tdHIpOwogICAgICAg
IH0KICAgICAgICAjc2VhcmNoLXdyYXAub3BlbiAjYnRuLXRvZGF5IHsgZGlzcGxh
eTogaW5saW5lLWZsZXg7IH0KICAgICAgICAjYnRuLXRvZGF5OmhvdmVyIHsgY29s
b3I6ICM0YTYyZDQ7IGJhY2tncm91bmQ6IHJnYmEoOTEsMTE1LDIzMiwuMTYpOyB9
CiAgICAgICAgI2J0bi10b2RheS5vbiB7CiAgICAgICAgICAgIGNvbG9yOiAjNWI3
M2U4OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDkxLDExNSwyMzIsLjE2
KTsKICAgICAgICAgICAgYm9yZGVyLWNvbG9yOiByZ2JhKDkxLDExNSwyMzIsLjMy
KTsKICAgICAgICB9CiAgICAgICAgI2J0bi10b2RheTpub3QoLm9uKSB7CiAgICAg
ICAgICAgIGNvbG9yOiB2YXIoLS10eHQzKTsKICAgICAgICAgICAgYmFja2dyb3Vu
ZDogcmdiYSgwLDAsMCwuMDQpOwogICAgICAgICAgICBib3JkZXItY29sb3I6IHJn
YmEoMCwwLDAsLjA2KTsKICAgICAgICB9CgogICAgICAgICNidG4tcGluIHsKICAg
ICAgICAgICAgd2lkdGg6IDI4cHg7IGhlaWdodDogMjhweDsgZmxleC1zaHJpbms6
IDA7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50
ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwogICAgICAgICAgICBib3JkZXI6
IDEuNXB4IHNvbGlkIHRyYW5zcGFyZW50OyBiYWNrZ3JvdW5kOiBub25lOyBjdXJz
b3I6IHBvaW50ZXI7CiAgICAgICAgICAgIGNvbG9yOiB2YXIoLS10eHQzKTsgYm9y
ZGVyLXJhZGl1czogdmFyKC0tcik7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJl
Z2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICAgICAg
dHJhbnNpdGlvbjogY29sb3IgdmFyKC0tdHIpLCBiYWNrZ3JvdW5kIHZhcigtLXRy
KSwgYm9yZGVyLWNvbG9yIHZhcigtLXRyKTsKICAgICAgICB9CiAgICAgICAgI2J0
bi1waW46aG92ZXIgeyBjb2xvcjogdmFyKC0tYWNjKTsgYmFja2dyb3VuZDogcmdi
YSg5MSwxMTUsMjMyLC4xKTsgfQogICAgICAgICNidG4tcGluLm9uICB7CiAgICAg
ICAgICAgIGNvbG9yOiB2YXIoLS1hY2MpOwogICAgICAgICAgICBiYWNrZ3JvdW5k
OiByZ2JhKDkxLDExNSwyMzIsLjE4KTsKICAgICAgICAgICAgYm9yZGVyLWNvbG9y
OiByZ2JhKDkxLDExNSwyMzIsLjU1KTsKICAgICAgICB9CiAgICAgICAgI2J0bi1w
aW4gc3ZnIHsgd2lkdGg6IDE0cHg7IGhlaWdodDogMTRweDsgZGlzcGxheTogYmxv
Y2s7IH0KCiAgICAgICAgI2J0bi1sb2NhdGUgewogICAgICAgICAgICB3aWR0aDog
MjhweDsgaGVpZ2h0OiAyOHB4OyBmbGV4LXNocmluazogMDsKICAgICAgICAgICAg
ZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250
ZW50OiBjZW50ZXI7CiAgICAgICAgICAgIGJvcmRlcjogbm9uZTsgYmFja2dyb3Vu
ZDogbm9uZTsgY3Vyc29yOiBwb2ludGVyOwogICAgICAgICAgICBjb2xvcjogdmFy
KC0tdHh0Myk7IGJvcmRlci1yYWRpdXM6IHZhcigtLXIpOwogICAgICAgICAgICAt
d2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7
CiAgICAgICAgICAgIHRyYW5zaXRpb246IGNvbG9yIHZhcigtLXRyKSwgYmFja2dy
b3VuZCB2YXIoLS10ciksIG9wYWNpdHkgdmFyKC0tdHIpOwogICAgICAgIH0KICAg
ICAgICAjYnRuLWxvY2F0ZTpob3Zlcjpub3QoOmRpc2FibGVkKSB7IGNvbG9yOiB2
YXIoLS1hY2MpOyBiYWNrZ3JvdW5kOiByZ2JhKDkxLDExNSwyMzIsLjEpOyB9CiAg
ICAgICAgI2J0bi1sb2NhdGU6ZGlzYWJsZWQgeyBvcGFjaXR5OiAuMzU7IGN1cnNv
cjogZGVmYXVsdDsgfQogICAgICAgICNidG4tbG9jYXRlLmhhcy10YXJnZXQgeyBj
b2xvcjogdmFyKC0tYWNjKTsgfQogICAgICAgICNidG4tbG9jYXRlLm9uIHsKICAg
ICAgICAgICAgY29sb3I6IHZhcigtLWFjYyk7CiAgICAgICAgICAgIGJhY2tncm91
bmQ6IHJnYmEoOTEsMTE1LDIzMiwuMTgpOwogICAgICAgIH0KICAgICAgICAjYnRu
LWxvY2F0ZSBzdmcgeyB3aWR0aDogMTVweDsgaGVpZ2h0OiAxNXB4OyBkaXNwbGF5
OiBibG9jazsgfQoKICAgICAgICAvKiDilIDilIAgUm93IDIg4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSAICovCiAgICAgICAgI3RhYnMgewogICAgICAgICAgICBkaXNwbGF5
OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDJweDsgZmxleC13cmFw
OiB3cmFwOwogICAgICAgICAgICBwYWRkaW5nOiA1cHggNnB4IDVweCA4cHg7IGZs
ZXgtc2hyaW5rOiAwOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZjJmNGY5Owog
ICAgICAgIH0KICAgICAgICAudGFiIHsKICAgICAgICAgICAgcGFkZGluZzogM3B4
IDdweDsgZm9udC1zaXplOiAxMXB4OyBjb2xvcjogdmFyKC0tdHh0Mik7IGN1cnNv
cjogcG9pbnRlcjsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogdmFyKC0tcik7
IHdoaXRlLXNwYWNlOiBub3dyYXA7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJl
Z2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICB9CiAg
ICAgICAgLnRhYjpob3ZlciB7IGNvbG9yOiB2YXIoLS10eHQpOyBiYWNrZ3JvdW5k
OiByZ2JhKDI1NSwyNTUsMjU1LC43KTsgfQogICAgICAgIC50YWIub24geyBjb2xv
cjogdmFyKC0tYWNjKTsgYmFja2dyb3VuZDogI2ZmZjsgYm94LXNoYWRvdzogMCAx
cHggMnB4IHJnYmEoMCwwLDAsLjA2KTsgZm9udC13ZWlnaHQ6IDYwMDsgfQogICAg
ICAgIC5iYWRnZSB7CiAgICAgICAgICAgIGRpc3BsYXk6IGlubGluZS1mbGV4OyBt
aW4td2lkdGg6IDE0cHg7IGhlaWdodDogMTRweDsgcGFkZGluZzogMCAzcHg7CiAg
ICAgICAgICAgIGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDog
Y2VudGVyOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiB2YXIoLS1hY2MpOyBjb2xv
cjogI2ZmZjsgZm9udC1zaXplOiA5cHg7IGJvcmRlci1yYWRpdXM6IDdweDsgZm9u
dC13ZWlnaHQ6IDcwMDsKICAgICAgICB9CiAgICAgICAgI3RhYi1hY3Rpb25zIHsK
ICAgICAgICAgICAgbWFyZ2luLWxlZnQ6IGF1dG87IGRpc3BsYXk6IGZsZXg7IGFs
aWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogNHB4OwogICAgICAgICAgICBjb2xvcjog
dmFyKC0tdHh0Myk7IGZvbnQtc2l6ZTogMTBweDsKICAgICAgICAgICAgLXdlYmtp
dC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAg
ICAgIH0KICAgICAgICAjYmFyLXR4dCB7IHdoaXRlLXNwYWNlOiBub3dyYXA7IH0K
ICAgICAgICAjYnRuLWNsciB7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFs
aWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwogICAg
ICAgICAgICB3aWR0aDogMjZweDsgaGVpZ2h0OiAyNnB4OyBib3JkZXI6IG5vbmU7
IGJhY2tncm91bmQ6IG5vbmU7IGNvbG9yOiB2YXIoLS10eHQzKTsKICAgICAgICAg
ICAgY3Vyc29yOiBwb2ludGVyOyBib3JkZXItcmFkaXVzOiB2YXIoLS1yKTsKICAg
ICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9u
OiBuby1kcmFnOwogICAgICAgICAgICB0cmFuc2l0aW9uOiBjb2xvciB2YXIoLS10
ciksIGJhY2tncm91bmQgdmFyKC0tdHIpOwogICAgICAgIH0KICAgICAgICAjYnRu
LWNscjpob3ZlciB7IGNvbG9yOiAjZmY3YjljOyBiYWNrZ3JvdW5kOiByZ2JhKDI1
NSwxMjMsMTU2LC4wOCk7IH0KICAgICAgICAjYnRuLWNsciBzdmcgeyB3aWR0aDog
MTRweDsgaGVpZ2h0OiAxNHB4OyBkaXNwbGF5OiBibG9jazsgfQoKICAgICAgICAv
KiDilIDilIAgTGlzdCDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAgKi8KICAgICAg
ICAjbGlzdCB7CiAgICAgICAgICAgIGZsZXg6IDE7IG92ZXJmbG93LXk6IGF1dG87
IHBhZGRpbmc6IDZweCA4cHggNnB4IDEwcHg7IGN1cnNvcjogZGVmYXVsdDsKICAg
ICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBkcmFnOyBhcHAtcmVnaW9uOiBk
cmFnOwogICAgICAgICAgICBtaW4taGVpZ2h0OiAwOwogICAgICAgIH0KICAgICAg
ICAjYnRuLXRvcCB7CiAgICAgICAgICAgIHBvc2l0aW9uOiBhYnNvbHV0ZTsgcmln
aHQ6IDEwcHg7IGJvdHRvbTogMTBweDsgei1pbmRleDogMjA7CiAgICAgICAgICAg
IHdpZHRoOiAyOHB4OyBoZWlnaHQ6IDI4cHg7IGJvcmRlcjogbm9uZTsgYm9yZGVy
LXJhZGl1czogNTAlOwogICAgICAgICAgICBkaXNwbGF5OiBub25lOyBhbGlnbi1p
dGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAgICAgICAg
ICAgYmFja2dyb3VuZDogI2ZmZjsgY29sb3I6IHZhcigtLXR4dDIpOwogICAgICAg
ICAgICBib3gtc2hhZG93OiAwIDJweCA4cHggcmdiYSgyNCwzMiw1NiwuMTYpOwog
ICAgICAgICAgICBjdXJzb3I6IHBvaW50ZXI7CiAgICAgICAgICAgIC13ZWJraXQt
YXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAg
ICAgICAgdHJhbnNpdGlvbjogYmFja2dyb3VuZCB2YXIoLS10ciksIGNvbG9yIHZh
cigtLXRyKSwgYm94LXNoYWRvdyB2YXIoLS10cik7CiAgICAgICAgfQogICAgICAg
ICNidG4tdG9wLm9uIHsgZGlzcGxheTogZmxleDsgfQogICAgICAgICNidG4tdG9w
OmhvdmVyIHsgY29sb3I6IHZhcigtLWFjYyk7IGJhY2tncm91bmQ6ICNlZGYxZmY7
IGJveC1zaGFkb3c6IDAgM3B4IDEwcHggcmdiYSg5MSwxMTUsMjMyLC4yNSk7IH0K
ICAgICAgICAjYnRuLXRvcCBzdmcgeyB3aWR0aDogMTRweDsgaGVpZ2h0OiAxNHB4
OyBkaXNwbGF5OiBibG9jazsgfQogICAgICAgICNlbXB0eSB7CiAgICAgICAgICAg
IGRpc3BsYXk6IG5vbmU7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGFsaWduLWl0
ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwogICAgICAgICAg
ICBwYWRkaW5nOiA0MHB4IDE2cHg7IGNvbG9yOiB2YXIoLS10eHQzKTsgZ2FwOiA4
cHg7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogZHJhZzsgYXBwLXJl
Z2lvbjogZHJhZzsKICAgICAgICB9CiAgICAgICAgI2VtcHR5Lm9uIHsgZGlzcGxh
eTogZmxleDsgfQogICAgICAgIC5lLWljbyB7CiAgICAgICAgICAgIHdpZHRoOiA0
OHB4OyBoZWlnaHQ6IDQ4cHg7IG9wYWNpdHk6IC45OwogICAgICAgICAgICBkaXNw
bGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6
IGNlbnRlcjsKICAgICAgICB9CiAgICAgICAgLmUtaWNvIHN2ZyB7IHdpZHRoOiA0
OHB4OyBoZWlnaHQ6IDQ4cHg7IGRpc3BsYXk6IGJsb2NrOyB9CiAgICAgICAgLmUt
dHh0IHsgZm9udC1zaXplOiAxMXB4OyB0ZXh0LWFsaWduOiBjZW50ZXI7IH0KICAg
ICAgICAubGlzdC1tb3JlIHsKICAgICAgICAgICAgdGV4dC1hbGlnbjogY2VudGVy
OyBwYWRkaW5nOiAxMHB4IDhweCAxNHB4OyBmb250LXNpemU6IDExcHg7CiAgICAg
ICAgICAgIGNvbG9yOiB2YXIoLS10eHQzKTsgLXdlYmtpdC1hcHAtcmVnaW9uOiBu
by1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgIH0KICAgICAgICAu
bGlzdC1tb3JlLmRvbmUgeyBkaXNwbGF5OiBub25lOyB9CgogICAgICAgIC5pdG0g
ewogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogZmxleC1z
dGFydDsgZ2FwOiA4cHg7CiAgICAgICAgICAgIHBhZGRpbmc6IDhweDsgbWFyZ2lu
LWJvdHRvbTogNXB4OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiB2YXIoLS1jYXJk
KTsgYm9yZGVyLXJhZGl1czogdmFyKC0tcik7IGN1cnNvcjogcG9pbnRlcjsKICAg
ICAgICAgICAgYm94LXNoYWRvdzogMCAxcHggM3B4IHJnYmEoMjQsMzIsNTYsLjA2
KTsKICAgICAgICAgICAgdHJhbnNpdGlvbjogYmFja2dyb3VuZCB2YXIoLS10ciks
IGJveC1zaGFkb3cgdmFyKC0tdHIpOwogICAgICAgICAgICAtd2Via2l0LWFwcC1y
ZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgICAg
IG92ZXJmbG93OiB2aXNpYmxlOwogICAgICAgIH0KICAgICAgICAuaXRtOmhvdmVy
IHsgYmFja2dyb3VuZDogdmFyKC0tY2FyZC1oKTsgYm94LXNoYWRvdzogMCAycHgg
NnB4IHJnYmEoMjQsMzIsNTYsLjEpOyB9CiAgICAgICAgLml0bS5zZWwgewogICAg
ICAgICAgICBib3gtc2hhZG93OiAwIDAgMCAycHggcmdiYSg5MSwxMTUsMjMyLC40
NSksIDAgMnB4IDhweCByZ2JhKDkxLDExNSwyMzIsLjE4KTsKICAgICAgICAgICAg
YmFja2dyb3VuZDogI2VkZjFmZjsKICAgICAgICB9CiAgICAgICAgLml0bS5tdWx0
aSB7CiAgICAgICAgICAgIGJveC1zaGFkb3c6IDAgMCAwIDEuNXB4IHJnYmEoOTEs
MTE1LDIzMiwuNTUpLCAwIDJweCA2cHggcmdiYSg5MSwxMTUsMjMyLC4xOCk7CiAg
ICAgICAgICAgIGJhY2tncm91bmQ6ICNlZWYyZmY7CiAgICAgICAgfQogICAgICAg
IC5pdG0ubXVsdGkuc2VsIHsKICAgICAgICAgICAgYm94LXNoYWRvdzogMCAwIDAg
MnB4IHJnYmEoOTEsMTE1LDIzMiwuNyksIDAgMnB4IDhweCByZ2JhKDkxLDExNSwy
MzIsLjIyKTsKICAgICAgICB9CgogICAgICAgICNtdWx0aS1jbnQgewogICAgICAg
ICAgICBkaXNwbGF5OiBub25lOyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5
LWNvbnRlbnQ6IGNlbnRlcjsKICAgICAgICAgICAgaGVpZ2h0OiAyMnB4OyBwYWRk
aW5nOiAwIDhweDsgbWFyZ2luLXJpZ2h0OiA0cHg7CiAgICAgICAgICAgIGJvcmRl
cjogbm9uZTsgYm9yZGVyLXJhZGl1czogMTFweDsgY3Vyc29yOiBwb2ludGVyOwog
ICAgICAgICAgICBiYWNrZ3JvdW5kOiB2YXIoLS1hY2MpOyBjb2xvcjogI2ZmZjsg
Zm9udC1zaXplOiAxMXB4OyBmb250LXdlaWdodDogNzAwOwogICAgICAgICAgICAt
d2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7
CiAgICAgICAgICAgIHRyYW5zaXRpb246IG9wYWNpdHkgdmFyKC0tdHIpLCBiYWNr
Z3JvdW5kIHZhcigtLXRyKTsKICAgICAgICB9CiAgICAgICAgI211bHRpLWNudDpo
b3ZlciB7IGJhY2tncm91bmQ6ICM0YTYyZDQ7IH0KICAgICAgICAjbXVsdGktY250
Lm9uIHsgZGlzcGxheTogaW5saW5lLWZsZXg7IH0KCiAgICAgICAgLmktaWNvIHsK
ICAgICAgICAgICAgd2lkdGg6IDI4cHg7IGhlaWdodDogMjhweDsgYm9yZGVyLXJh
ZGl1czogdmFyKC0tcik7IGRpc3BsYXk6IGZsZXg7CiAgICAgICAgICAgIGFsaWdu
LWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOyBmbGV4LXNo
cmluazogMDsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2VkZjJmZjsgY29sb3I6
IHZhcigtLWFjYyk7CiAgICAgICAgICAgIHBvc2l0aW9uOiByZWxhdGl2ZTsgb3Zl
cmZsb3c6IHZpc2libGU7CiAgICAgICAgfQogICAgICAgIC5pLWljbyBzdmcgeyB3
aWR0aDogMTZweDsgaGVpZ2h0OiAxNnB4OyBkaXNwbGF5OiBibG9jazsgfQogICAg
ICAgIC5pLWljby5mdC1pbWcgeyBjb2xvcjogIzdhZDdmZjsgfQogICAgICAgIC5p
LWljby5mdC16aXAgeyBjb2xvcjogIzhhYjRmZjsgfQogICAgICAgIC5pLWljby5m
dC1kaXIgeyBjb2xvcjogI2ZmZDU2YTsgfQogICAgICAgIC5pLWljby5mdC1haGsg
eyBjb2xvcjogIzZkZmY5YTsgfQogICAgICAgIC5pLWljby5mdC1sbmssIC5pLWlj
by5mdC1kb2MgeyBjb2xvcjogI2E5YmRkMDsgfQogICAgICAgIC5pLXVzZWQgewog
ICAgICAgICAgICBwb3NpdGlvbjogYWJzb2x1dGU7IHJpZ2h0OiAwOyBib3R0b206
IDA7CiAgICAgICAgICAgIHdpZHRoOiAxM3B4OyBoZWlnaHQ6IDEzcHg7IGJvcmRl
ci1yYWRpdXM6IDUwJTsKICAgICAgICAgICAgYmFja2dyb3VuZDogIzIyYzU1ZTsg
Ym9yZGVyOiAxLjVweCBzb2xpZCAjZmZmOwogICAgICAgICAgICBkaXNwbGF5OiBm
bGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRl
cjsKICAgICAgICAgICAgcG9pbnRlci1ldmVudHM6IG5vbmU7IHotaW5kZXg6IDM7
CiAgICAgICAgICAgIGJveC1zaGFkb3c6IDAgMXB4IDJweCByZ2JhKDAsMCwwLC4x
Nik7CiAgICAgICAgICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlKDMwJSwgMzAlKTsK
ICAgICAgICB9CiAgICAgICAgLmktdXNlZCBzdmcgeyB3aWR0aDogOXB4OyBoZWln
aHQ6IDlweDsgY29sb3I6ICNmZmY7IGRpc3BsYXk6IGJsb2NrOyB9CgogICAgICAg
IC5pLWxpbmstY2FyZCB7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGZsZXgt
ZGlyZWN0aW9uOiBjb2x1bW47IGdhcDogNHB4OyB3aWR0aDogMTAwJTsKICAgICAg
ICB9CiAgICAgICAgLmktbGluay10aXRsZSB7CiAgICAgICAgICAgIGZvbnQtc2l6
ZTogMTNweDsgZm9udC13ZWlnaHQ6IDYwMDsgY29sb3I6IHZhcigtLXR4dCk7CiAg
ICAgICAgICAgIGRpc3BsYXk6IC13ZWJraXQtYm94OyAtd2Via2l0LWJveC1vcmll
bnQ6IHZlcnRpY2FsOyAtd2Via2l0LWxpbmUtY2xhbXA6IDI7CiAgICAgICAgICAg
IG92ZXJmbG93OiBoaWRkZW47IHdvcmQtYnJlYWs6IGJyZWFrLXdvcmQ7CiAgICAg
ICAgfQogICAgICAgIC5pLWxpbmstdXJsIHsKICAgICAgICAgICAgZm9udDogNjAw
IDEyLjVweC8xLjU1ICdTZWdvZSBVSSBWYXJpYWJsZSBUZXh0JywnU2Vnb2UgVUkn
LCdNaWNyb3NvZnQgWWFIZWkgVUknLHNhbnMtc2VyaWY7CiAgICAgICAgICAgIGNv
bG9yOiB2YXIoLS10eHQyKTsKICAgICAgICAgICAgbGV0dGVyLXNwYWNpbmc6IC4w
MWVtOwogICAgICAgICAgICB3b3JkLWJyZWFrOiBicmVhay1hbGw7IHdoaXRlLXNw
YWNlOiBwcmUtd3JhcDsKICAgICAgICAgICAgZGlzcGxheTogLXdlYmtpdC1ib3g7
IC13ZWJraXQtYm94LW9yaWVudDogdmVydGljYWw7IC13ZWJraXQtbGluZS1jbGFt
cDogMjsKICAgICAgICAgICAgb3ZlcmZsb3c6IGhpZGRlbjsKICAgICAgICB9CiAg
ICAgICAgLmktbGluay11cmwuZXhwYW5kZWQgewogICAgICAgICAgICAtd2Via2l0
LWxpbmUtY2xhbXA6IHVuc2V0OwogICAgICAgICAgICBvdmVyZmxvdzogdmlzaWJs
ZTsKICAgICAgICB9CiAgICAgICAgLmktbGluay1hY3Rpb25zIHsKICAgICAgICAg
ICAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1j
b250ZW50OiBmbGV4LWVuZDsKICAgICAgICAgICAgZ2FwOiA2cHg7IG1hcmdpbi10
b3A6IDJweDsKICAgICAgICB9CiAgICAgICAgLmktbGluay1zaG90IHsKICAgICAg
ICAgICAgd2lkdGg6IDEwMCU7IGhlaWdodDogODhweDsgYm9yZGVyLXJhZGl1czog
dmFyKC0tcik7IG92ZXJmbG93OiBoaWRkZW47CiAgICAgICAgICAgIGJhY2tncm91
bmQ6ICNlZWYxZjc7IGJvcmRlcjogMXB4IHNvbGlkICNlNGU4ZjA7CiAgICAgICAg
ICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnkt
Y29udGVudDogY2VudGVyOwogICAgICAgICAgICBjb2xvcjogIzlhYTBiMDsgZm9u
dC1zaXplOiAxMHB4OwogICAgICAgIH0KICAgICAgICAuaS1saW5rLXNob3QgaW1n
IHsKICAgICAgICAgICAgd2lkdGg6IDEwMCU7IGhlaWdodDogMTAwJTsgb2JqZWN0
LWZpdDogY292ZXI7IGRpc3BsYXk6IGJsb2NrOwogICAgICAgIH0KICAgICAgICAu
aS1saW5rLXNob3QuaGlkZSB7IGRpc3BsYXk6IG5vbmU7IH0KICAgICAgICAuaS1p
Y28ubGluayB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNlZWY2ZmY7IGNvbG9y
OiAjM2I4MmY2OwogICAgICAgICAgICBvdmVyZmxvdzogdmlzaWJsZTsKICAgICAg
ICB9CiAgICAgICAgLmktaWNvLmxpbmsgaW1nIHsKICAgICAgICAgICAgd2lkdGg6
IDE4cHg7IGhlaWdodDogMThweDsgYm9yZGVyLXJhZGl1czogM3B4OyBkaXNwbGF5
OiBibG9jazsKICAgICAgICAgICAgb2JqZWN0LWZpdDogY29udGFpbjsKICAgICAg
ICB9CiAgICAgICAgLmktb3Blbi1idG4gewogICAgICAgICAgICBoZWlnaHQ6IDIy
cHg7IHBhZGRpbmc6IDAgOXB4OyBmbGV4LXNocmluazogMDsKICAgICAgICAgICAg
Ym9yZGVyOiAxcHggc29saWQgcmdiYSg5MSwxMTUsMjMyLC4yOCk7IGJvcmRlci1y
YWRpdXM6IDZweDsgY3Vyc29yOiBwb2ludGVyOwogICAgICAgICAgICBiYWNrZ3Jv
dW5kOiByZ2JhKDkxLDExNSwyMzIsLjA3KTsgY29sb3I6ICM3YjhmZDA7IGZvbnQt
c2l6ZTogMTFweDsgZm9udC13ZWlnaHQ6IDYwMDsKICAgICAgICAgICAgLXdlYmtp
dC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAg
ICAgICAgICB0cmFuc2l0aW9uOiBiYWNrZ3JvdW5kIHZhcigtLXRyKSwgY29sb3Ig
dmFyKC0tdHIpLCBib3JkZXItY29sb3IgdmFyKC0tdHIpOwogICAgICAgIH0KICAg
ICAgICAuaS1vcGVuLWJ0bjpob3ZlciB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6
IHJnYmEoOTEsMTE1LDIzMiwuMTQpOyBjb2xvcjogdmFyKC0tYWNjKTsKICAgICAg
ICAgICAgYm9yZGVyLWNvbG9yOiByZ2JhKDkxLDExNSwyMzIsLjQ1KTsKICAgICAg
ICB9CiAgICAgICAgLmktc3JjLWJ0biB7CiAgICAgICAgICAgIGhlaWdodDogMjJw
eDsgcGFkZGluZzogMCA5cHg7IGZsZXgtc2hyaW5rOiAwOwogICAgICAgICAgICBi
b3JkZXI6IDFweCBzb2xpZCByZ2JhKDEwNywxMTIsMTI4LC4yMik7IGJvcmRlci1y
YWRpdXM6IDZweDsgY3Vyc29yOiBwb2ludGVyOwogICAgICAgICAgICBiYWNrZ3Jv
dW5kOiByZ2JhKDEwNywxMTIsMTI4LC4wNik7IGNvbG9yOiAjOGE5MGEwOyBmb250
LXNpemU6IDExcHg7IGZvbnQtd2VpZ2h0OiA2MDA7CiAgICAgICAgICAgIC13ZWJr
aXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAg
ICAgICAgICAgdHJhbnNpdGlvbjogYmFja2dyb3VuZCB2YXIoLS10ciksIGNvbG9y
IHZhcigtLXRyKSwgYm9yZGVyLWNvbG9yIHZhcigtLXRyKTsKICAgICAgICB9CiAg
ICAgICAgLmktc3JjLWJ0bjpob3ZlciB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6
IHJnYmEoMTA3LDExMiwxMjgsLjEyKTsgY29sb3I6IHZhcigtLXR4dDIpOwogICAg
ICAgICAgICBib3JkZXItY29sb3I6IHJnYmEoMTA3LDExMiwxMjgsLjQpOwogICAg
ICAgIH0KICAgICAgICAuaXRtLmp1bXAtZmxhc2ggewogICAgICAgICAgICBib3gt
c2hhZG93OiAwIDAgMCAycHggcmdiYSg5MSwxMTUsMjMyLC41NSksIDAgMnB4IDEw
cHggcmdiYSg5MSwxMTUsMjMyLC4yMik7CiAgICAgICAgICAgIGJhY2tncm91bmQ6
ICNlOGVkZmY7CiAgICAgICAgICAgIHRyYW5zaXRpb246IGJhY2tncm91bmQgLjM1
cyBlYXNlLCBib3gtc2hhZG93IC4zNXMgZWFzZTsKICAgICAgICB9CgogICAgICAg
IC5pLWJvZHkgeyBmbGV4OiAxOyBtaW4td2lkdGg6IDA7IGRpc3BsYXk6IGZsZXg7
IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IH0KICAgICAgICAuaS1wcmV2LCAuaS1u
YW1lIHsKICAgICAgICAgICAgZm9udC1zaXplOiAxM3B4OyBmb250LXdlaWdodDog
NTAwOyBjb2xvcjogdmFyKC0tdHh0KTsgd29yZC1icmVhazogYnJlYWstYWxsOwog
ICAgICAgICAgICB3aGl0ZS1zcGFjZTogcHJlLXdyYXA7IC8qIOaUr+aMgeWkmuaW
h+S7ti/lpJrooYzmlofmnKzmjaLooYzmmL7npLogKi8KICAgICAgICB9CiAgICAg
ICAgLmktcHJldiB7CiAgICAgICAgICAgIGRpc3BsYXk6IC13ZWJraXQtYm94OyAt
d2Via2l0LWJveC1vcmllbnQ6IHZlcnRpY2FsOyAtd2Via2l0LWxpbmUtY2xhbXA6
IDU7IG92ZXJmbG93OiBoaWRkZW47CiAgICAgICAgfQogICAgICAgIC5pLW5hbWUg
ewogICAgICAgICAgICBkaXNwbGF5OiAtd2Via2l0LWJveDsgLXdlYmtpdC1ib3gt
b3JpZW50OiB2ZXJ0aWNhbDsgLXdlYmtpdC1saW5lLWNsYW1wOiAyOyBvdmVyZmxv
dzogaGlkZGVuOwogICAgICAgIH0KICAgICAgICAvKiBGaWxlIGNsaXAgd2hvc2Ug
cGF0aChzKSBubyBsb25nZXIgZXhpc3Qg4oCUIGxpZ2h0IGJvbGQgZ3JheSBzdHJp
a2UgKi8KICAgICAgICAuaXRtLmdvbmUgLmktbmFtZSB7CiAgICAgICAgICAgIGNv
bG9yOiAjOWFhMGIwOwogICAgICAgICAgICB0ZXh0LWRlY29yYXRpb246IGxpbmUt
dGhyb3VnaDsKICAgICAgICAgICAgdGV4dC1kZWNvcmF0aW9uLXRoaWNrbmVzczog
MnB4OwogICAgICAgICAgICB0ZXh0LWRlY29yYXRpb24tY29sb3I6IHJnYmEoMTU0
LCAxNjAsIDE3NiwgLjU1KTsKICAgICAgICAgICAgdGV4dC1kZWNvcmF0aW9uLXNr
aXAtaW5rOiBub25lOwogICAgICAgIH0KICAgICAgICAuaXRtLmdvbmUgLmktaWNv
IHsgb3BhY2l0eTogLjU1OyB9CiAgICAgICAgLml0bS5nb25lIC5pLXRodW1iLXdy
YXAgeyBvcGFjaXR5OiAuNTU7IH0KICAgICAgICAuaS1wcmV2LnVybCB7IGNvbG9y
OiB2YXIoLS1hY2MpOyB9CiAgICAgICAgLmktdGh1bWItd3JhcCB7CiAgICAgICAg
ICAgIHdpZHRoOiAxMDAlOyBtaW4taGVpZ2h0OiA0OHB4OyBtYXgtaGVpZ2h0OiAx
ODBweDsgbWFyZ2luLWJvdHRvbTogNHB4OwogICAgICAgICAgICBkaXNwbGF5OiBm
bGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRl
cjsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2YzZjVmOTsgYm9yZGVyLXJhZGl1
czogdmFyKC0tcik7IG92ZXJmbG93OiBoaWRkZW47CiAgICAgICAgfQogICAgICAg
IC5pLXRodW1iIHsgbWF4LXdpZHRoOiAxMDAlOyBtYXgtaGVpZ2h0OiAxODBweDsg
d2lkdGg6IGF1dG87IGhlaWdodDogYXV0bzsgb2JqZWN0LWZpdDogY29udGFpbjsg
ZGlzcGxheTogYmxvY2s7IH0KCiAgICAgICAgLyogTWV0YSBiYXI6IHRpbWUgbGVm
dCB8IGV4cGFuZCBjZW50ZXIgfCB0YWdzIHJpZ2h0ICovCiAgICAgICAgLmktbWV0
YSB7CiAgICAgICAgICAgIGRpc3BsYXk6IGdyaWQ7CiAgICAgICAgICAgIGdyaWQt
dGVtcGxhdGUtY29sdW1uczogMWZyIGF1dG8gMWZyOwogICAgICAgICAgICBhbGln
bi1pdGVtczogY2VudGVyOwogICAgICAgICAgICBnYXA6IDRweDsKICAgICAgICAg
ICAgbWFyZ2luLXRvcDogNHB4OwogICAgICAgICAgICB3aWR0aDogMTAwJTsKICAg
ICAgICB9CiAgICAgICAgLmktbWV0YSAuaS10aW1lIHsganVzdGlmeS1zZWxmOiBz
dGFydDsgfQogICAgICAgIC5pLW1ldGEtY2VudGVyIHsKICAgICAgICAgICAganVz
dGlmeS1zZWxmOiBjZW50ZXI7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFs
aWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwogICAg
ICAgICAgICBnYXA6IDRweDsKICAgICAgICAgICAgbWluLXdpZHRoOiAxcHg7IC8q
IGtlZXAgY2VudGVyIGNvbHVtbiBldmVuIHdoZW4gZXhwYW5kIGlzIGhpZGRlbiAq
LwogICAgICAgIH0KICAgICAgICAuaS1tZXRhLXJpZ2h0IHsKICAgICAgICAgICAg
anVzdGlmeS1zZWxmOiBlbmQ7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFs
aWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogNXB4OyBmbGV4LXdyYXA6IHdyYXA7CiAg
ICAgICAgICAgIGp1c3RpZnktY29udGVudDogZmxleC1lbmQ7CiAgICAgICAgfQog
ICAgICAgIC5pLW1ldGEtcmlnaHQudGV4dC1tZXRhIHsKICAgICAgICAgICAgZmxl
eC13cmFwOiBub3dyYXA7CiAgICAgICAgICAgIGdhcDogNHB4OwogICAgICAgIH0K
ICAgICAgICAuaS10aW1lLCAuaS10YWcgeyBmb250LXNpemU6IDEwcHg7IGNvbG9y
OiB2YXIoLS10eHQzKTsgfQogICAgICAgIC5pLXRhZyB7CiAgICAgICAgICAgIGJh
Y2tncm91bmQ6ICNmMWYzZjg7IHBhZGRpbmc6IDAgNXB4OyBib3JkZXItcmFkaXVz
OiAzcHg7CiAgICAgICAgICAgIHdoaXRlLXNwYWNlOiBub3dyYXA7IGZsZXgtc2hy
aW5rOiAwOyBsaW5lLWhlaWdodDogMS40OwogICAgICAgIH0KICAgICAgICAuaS10
YWcubWQtYmFkZ2UgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZThlZGZmOyBj
b2xvcjogdmFyKC0tYWNjKTsgZm9udC13ZWlnaHQ6IDcwMDsKICAgICAgICAgICAg
bWluLXdpZHRoOiAyMnB4OyB0ZXh0LWFsaWduOiBjZW50ZXI7IGJveC1zaXppbmc6
IGJvcmRlci1ib3g7CiAgICAgICAgfQogICAgICAgIC5pLXRhZy5tZC1iYWRnZS5v
ZmYgeyB2aXNpYmlsaXR5OiBoaWRkZW47IH0KICAgICAgICAuaS1jaGFycyB7CiAg
ICAgICAgICAgIGZvbnQtc2l6ZTogMTBweDsgY29sb3I6IHZhcigtLXR4dDMpOwog
ICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZjFmM2Y4OyBwYWRkaW5nOiAwIDVweDsg
Ym9yZGVyLXJhZGl1czogM3B4OwogICAgICAgICAgICBmb250LXZhcmlhbnQtbnVt
ZXJpYzogdGFidWxhci1udW1zOwogICAgICAgICAgICB3aGl0ZS1zcGFjZTogbm93
cmFwOwogICAgICAgICAgICBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRl
bXM6IGJhc2VsaW5lOyBnYXA6IDJweDsKICAgICAgICB9CiAgICAgICAgLmktY2hh
cnMgLm4gewogICAgICAgICAgICBkaXNwbGF5OiBpbmxpbmUtYmxvY2s7CiAgICAg
ICAgICAgIG1pbi13aWR0aDogNGNoOwogICAgICAgICAgICB0ZXh0LWFsaWduOiBy
aWdodDsKICAgICAgICAgICAgZm9udC1mYW1pbHk6ICdDYXNjYWRpYSBNb25vJywg
J0NvbnNvbGFzJywgJ1NhcmFzYSBNb25vIFNDJywgdWktbW9ub3NwYWNlLCBtb25v
c3BhY2U7CiAgICAgICAgICAgIGZvbnQtd2VpZ2h0OiA2MDA7CiAgICAgICAgICAg
IGNvbG9yOiB2YXIoLS10eHQyKTsKICAgICAgICB9CiAgICAgICAgLmktc3JjLWlj
byB7CiAgICAgICAgICAgIHdpZHRoOiAxNHB4OyBoZWlnaHQ6IDE0cHg7IGZsZXgt
c2hyaW5rOiAwOwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiAycHg7IG9iamVj
dC1maXQ6IGNvbnRhaW47CiAgICAgICAgICAgIGRpc3BsYXk6IGJsb2NrOwogICAg
ICAgIH0KICAgICAgICAuaS1udW0gewogICAgICAgICAgICBkaXNwbGF5OiBmbGV4
OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBhbGlnbi1pdGVtczogZmxleC1lbmQ7
CiAgICAgICAgICAgIGp1c3RpZnktY29udGVudDogc3BhY2UtYmV0d2VlbjsKICAg
ICAgICAgICAgYWxpZ24tc2VsZjogc3RyZXRjaDsKICAgICAgICAgICAgZm9udC1z
aXplOiAxMHB4OyBjb2xvcjogdmFyKC0tdHh0Myk7IG1pbi13aWR0aDogMTZweDsK
ICAgICAgICAgICAgdGV4dC1hbGlnbjogcmlnaHQ7IGZsZXgtc2hyaW5rOiAwOwog
ICAgICAgICAgICBwYWRkaW5nLXRvcDogMnB4OwogICAgICAgIH0KICAgICAgICAu
aS1udW0gLmktc3JjLWljbyB7IHdpZHRoOiAxNnB4OyBoZWlnaHQ6IDE2cHg7IG1h
cmdpbi10b3A6IGF1dG87IH0KCiAgICAgICAgLmktZXhwYW5kLWJ0biB7CiAgICAg
ICAgICAgIGJvcmRlcjogbm9uZTsgYmFja2dyb3VuZDogbm9uZTsgY3Vyc29yOiBw
b2ludGVyOwogICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0Myk7IGZvbnQtc2l6
ZTogMTBweDsgcGFkZGluZzogMXB4IDZweDsKICAgICAgICAgICAgYm9yZGVyLXJh
ZGl1czogOHB4OyBkaXNwbGF5OiBub25lOyBhbGlnbi1pdGVtczogY2VudGVyOyBn
YXA6IDJweDsKICAgICAgICAgICAgdHJhbnNpdGlvbjogY29sb3IgdmFyKC0tdHIp
LCBiYWNrZ3JvdW5kIHZhcigtLXRyKTsKICAgICAgICAgICAgLXdlYmtpdC1hcHAt
cmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgIH0K
ICAgICAgICAuaS1leHBhbmQtYnRuLm9uIHsgZGlzcGxheTogaW5saW5lLWZsZXg7
IH0KICAgICAgICAuaS1leHBhbmQtYnRuOmhvdmVyIHsgY29sb3I6IHZhcigtLWFj
Yyk7IGJhY2tncm91bmQ6IHJnYmEoOTEsMTE1LDIzMiwuMDgpOyB9CiAgICAgICAg
LmktcHJldi5leHBhbmRlZCwgLmktbmFtZS5leHBhbmRlZCB7CiAgICAgICAgICAg
IC13ZWJraXQtbGluZS1jbGFtcDogdW5zZXQ7CiAgICAgICAgICAgIG92ZXJmbG93
OiB2aXNpYmxlOwogICAgICAgIH0KICAgICAgICAuaS1maWxlLWRldGFpbCB7CiAg
ICAgICAgICAgIGRpc3BsYXk6IG5vbmU7CiAgICAgICAgICAgIG1hcmdpbi10b3A6
IDRweDsKICAgICAgICAgICAgcGFkZGluZzogMDsKICAgICAgICAgICAgYmFja2dy
b3VuZDogbm9uZTsKICAgICAgICAgICAgYm9yZGVyOiBub25lOwogICAgICAgIH0K
ICAgICAgICAuaS1maWxlLWRldGFpbC5vbiB7IGRpc3BsYXk6IGJsb2NrOyB9CiAg
ICAgICAgLmZkLWJsb2NrIHsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgZmxl
eC1kaXJlY3Rpb246IGNvbHVtbjsgZ2FwOiA2cHg7CiAgICAgICAgfQogICAgICAg
IC5mZC1ibG9jayArIC5mZC1ibG9jayB7IG1hcmdpbi10b3A6IDhweDsgfQogICAg
ICAgIC5mZC1wYXRoIHsKICAgICAgICAgICAgd2lkdGg6IDEwMCU7CiAgICAgICAg
ICAgIGZvbnQ6IDYwMCAxMnB4LzEuNTUgJ1NlZ29lIFVJIFZhcmlhYmxlIFRleHQn
LCdTZWdvZSBVSScsJ01pY3Jvc29mdCBZYUhlaSBVSScsc2Fucy1zZXJpZjsKICAg
ICAgICAgICAgY29sb3I6IHZhcigtLXR4dDIpOwogICAgICAgICAgICBsZXR0ZXIt
c3BhY2luZzogLjAxZW07CiAgICAgICAgICAgIHdvcmQtYnJlYWs6IGJyZWFrLWFs
bDsKICAgICAgICAgICAgdXNlci1zZWxlY3Q6IHRleHQ7CiAgICAgICAgICAgIC13
ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsK
ICAgICAgICB9CiAgICAgICAgLmZkLXBhdGgubGl2ZSB7IGN1cnNvcjogcG9pbnRl
cjsgfQogICAgICAgIC5mZC1wYXRoLmxpdmU6aG92ZXIgeyBjb2xvcjogdmFyKC0t
YWNjKTsgfQogICAgICAgIC5mZC1wYXRoLmRlYWQgewogICAgICAgICAgICBjb2xv
cjogIzlhYTBiMDsKICAgICAgICAgICAgdGV4dC1kZWNvcmF0aW9uOiBsaW5lLXRo
cm91Z2g7CiAgICAgICAgICAgIHRleHQtZGVjb3JhdGlvbi10aGlja25lc3M6IDJw
eDsKICAgICAgICAgICAgdGV4dC1kZWNvcmF0aW9uLWNvbG9yOiByZ2JhKDE1NCwg
MTYwLCAxNzYsIC41NSk7CiAgICAgICAgICAgIHRleHQtZGVjb3JhdGlvbi1za2lw
LWluazogbm9uZTsKICAgICAgICAgICAgY3Vyc29yOiBkZWZhdWx0OwogICAgICAg
IH0KICAgICAgICAuZmQtYWN0aW9ucyB7CiAgICAgICAgICAgIGRpc3BsYXk6IGZs
ZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogZmxleC1l
bmQ7CiAgICAgICAgICAgIGdhcDogOHB4OyBmbGV4LXdyYXA6IHdyYXA7CiAgICAg
ICAgfQogICAgICAgIC5mZC1idG4gewogICAgICAgICAgICBib3JkZXI6IG5vbmU7
IGJhY2tncm91bmQ6IG5vbmU7IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICAgICAg
Y29sb3I6IHZhcigtLXR4dDMpOyBmb250LXNpemU6IDEwcHg7IGZvbnQtd2VpZ2h0
OiA2MDA7CiAgICAgICAgICAgIHBhZGRpbmc6IDFweCAycHg7IGRpc3BsYXk6IGlu
bGluZS1mbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDJweDsKICAgICAg
ICAgICAgd2hpdGUtc3BhY2U6IG5vd3JhcDsKICAgICAgICAgICAgLXdlYmtpdC1h
cHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAg
ICAgICB0cmFuc2l0aW9uOiBjb2xvciB2YXIoLS10cik7CiAgICAgICAgfQogICAg
ICAgIC5mZC1idG46aG92ZXIgeyBjb2xvcjogdmFyKC0tYWNjKTsgfQogICAgICAg
IC5mZC1idG4ub2sgeyBjb2xvcjogIzFmN2E1NTsgfQoKICAgICAgICAvKiDilIDi
lIAgQ29udGV4dCBtZW51IOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgCAqLwogICAgICAgICNjdHggewogICAgICAgICAgICBw
b3NpdGlvbjogZml4ZWQ7IHotaW5kZXg6IDk5OTk7IG1pbi13aWR0aDogMTMycHg7
IGRpc3BsYXk6IG5vbmU7IHBhZGRpbmc6IDRweDsKICAgICAgICAgICAgYmFja2dy
b3VuZDogI2ZmZjsgYm9yZGVyLXJhZGl1czogdmFyKC0tcik7IGJveC1zaGFkb3c6
IDAgNnB4IDE2cHggcmdiYSgwLDAsMCwuMTQpOwogICAgICAgICAgICAtd2Via2l0
LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAg
ICAgfQogICAgICAgICNjdHgub24geyBkaXNwbGF5OiBibG9jazsgfQogICAgICAg
IC5jLWl0ZW0gewogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVt
czogY2VudGVyOyBnYXA6IDdweDsgcGFkZGluZzogNnB4IDlweDsKICAgICAgICAg
ICAgYm9yZGVyLXJhZGl1czogdmFyKC0tcik7IGN1cnNvcjogcG9pbnRlcjsgZm9u
dC1zaXplOiAxMXB4OyBjb2xvcjogdmFyKC0tdHh0KTsKICAgICAgICB9CiAgICAg
ICAgLmMtaXRlbTpob3ZlciB7IGJhY2tncm91bmQ6ICNmMmY0Zjk7IH0KICAgICAg
ICAuYy1pdGVtLmRhbmdlciB7IGNvbG9yOiAjZmY3YjljOyB9CiAgICAgICAgLmMt
c2VwIHsgaGVpZ2h0OiAxcHg7IGJhY2tncm91bmQ6ICNlY2VmZjU7IG1hcmdpbjog
M3B4IDA7IH0KICAgICAgICAuYy1pY28geyB3aWR0aDogMTRweDsgdGV4dC1hbGln
bjogY2VudGVyOyB9CgogICAgICAgIC8qIOKUgOKUgCBDbGVhciBjb25maXJtIOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgCAqLwog
ICAgICAgICNjbHItZGxnIHsKICAgICAgICAgICAgZGlzcGxheTogbm9uZTsgcG9z
aXRpb246IGZpeGVkOyBpbnNldDogMDsgei1pbmRleDogMTAwMDA7CiAgICAgICAg
ICAgIGJhY2tncm91bmQ6IHJnYmEoMjAsIDIyLCAzNSwgLjQyKTsKICAgICAgICAg
ICAgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7
CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJl
Z2lvbjogbm8tZHJhZzsKICAgICAgICB9CiAgICAgICAgI2Nsci1kbGcub24geyBk
aXNwbGF5OiBmbGV4OyB9CiAgICAgICAgLmNsci1ib3ggewogICAgICAgICAgICB3
aWR0aDogbWluKDI4MHB4LCBjYWxjKDEwMCUgLSAzMnB4KSk7CiAgICAgICAgICAg
IGJhY2tncm91bmQ6ICNmZmY7IGJvcmRlci1yYWRpdXM6IDEycHg7CiAgICAgICAg
ICAgIGJveC1zaGFkb3c6IDAgMTJweCAzMnB4IHJnYmEoMCwwLDAsLjE4KTsKICAg
ICAgICAgICAgcGFkZGluZzogMTZweCAxNnB4IDE0cHg7IGNvbG9yOiB2YXIoLS10
eHQpOwogICAgICAgIH0KICAgICAgICAuY2xyLXRpdGxlIHsgZm9udC1zaXplOiAx
NHB4OyBmb250LXdlaWdodDogNzAwOyBtYXJnaW4tYm90dG9tOiA2cHg7IH0KICAg
ICAgICAuY2xyLWRlc2MgeyBmb250LXNpemU6IDExcHg7IGNvbG9yOiB2YXIoLS10
eHQzKTsgbGluZS1oZWlnaHQ6IDEuNTsgbWFyZ2luLWJvdHRvbTogMTJweDsgfQog
ICAgICAgIC5jbHItY2hlY2sgewogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBh
bGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDdweDsKICAgICAgICAgICAgZm9udC1z
aXplOiAxMnB4OyBjb2xvcjogdmFyKC0tdHh0KTsgY3Vyc29yOiBwb2ludGVyOwog
ICAgICAgICAgICB1c2VyLXNlbGVjdDogbm9uZTsgbWFyZ2luLWJvdHRvbTogMTRw
eDsKICAgICAgICB9CiAgICAgICAgLmNsci1jaGVjayBpbnB1dCB7CiAgICAgICAg
ICAgIHdpZHRoOiAxNHB4OyBoZWlnaHQ6IDE0cHg7IGFjY2VudC1jb2xvcjogdmFy
KC0tYWNjKTsgY3Vyc29yOiBwb2ludGVyOwogICAgICAgIH0KICAgICAgICAuY2xy
LWJ0bnMgeyBkaXNwbGF5OiBmbGV4OyBnYXA6IDhweDsganVzdGlmeS1jb250ZW50
OiBmbGV4LWVuZDsgfQogICAgICAgIC5jbHItYnRucyBidXR0b24gewogICAgICAg
ICAgICBib3JkZXI6IG5vbmU7IGJvcmRlci1yYWRpdXM6IDhweDsgcGFkZGluZzog
N3B4IDE0cHg7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTJweDsgY3Vyc29yOiBw
b2ludGVyOyBmb250LXdlaWdodDogNjAwOwogICAgICAgICAgICB0cmFuc2l0aW9u
OiBiYWNrZ3JvdW5kIHZhcigtLXRyKSwgY29sb3IgdmFyKC0tdHIpOwogICAgICAg
IH0KICAgICAgICAjY2xyLWNhbmNlbCB7IGJhY2tncm91bmQ6ICNmMWYzZjg7IGNv
bG9yOiB2YXIoLS10eHQyKTsgfQogICAgICAgICNjbHItY2FuY2VsOmhvdmVyIHsg
YmFja2dyb3VuZDogI2U2ZTlmMjsgfQogICAgICAgICNjbHItb2sgeyBiYWNrZ3Jv
dW5kOiByZ2JhKDI1NSwxMjMsMTU2LC4xNCk7IGNvbG9yOiAjZTg1YTdhOyB9CiAg
ICAgICAgI2Nsci1vazpob3ZlciB7IGJhY2tncm91bmQ6IHJnYmEoMjU1LDEyMywx
NTYsLjI0KTsgfQoKICAgICAgICAvKiDilIDilIAgRmlsZSBwYXRoIHRpcCDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAgKi8KICAg
ICAgICAjcGF0aC10aXAgewogICAgICAgICAgICBkaXNwbGF5OiBub25lOyBwb3Np
dGlvbjogZml4ZWQ7IHotaW5kZXg6IDEwMDAxOwogICAgICAgICAgICB3aWR0aDog
bWluKDMyMHB4LCBjYWxjKDEwMHZ3IC0gMTZweCkpOwogICAgICAgICAgICBtYXgt
aGVpZ2h0OiBtaW4oMjgwcHgsIGNhbGMoMTAwdmggLSAyNHB4KSk7CiAgICAgICAg
ICAgIG92ZXJmbG93OiBhdXRvOwogICAgICAgICAgICBwYWRkaW5nOiAwOwogICAg
ICAgICAgICBiYWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGllbnQoMTY1ZGVnLCAjZmZm
ZmZmIDAlLCAjZjZmOGZjIDEwMCUpOwogICAgICAgICAgICBib3JkZXI6IDFweCBz
b2xpZCByZ2JhKDcwLCA4NCwgMTIwLCAuMSk7CiAgICAgICAgICAgIGJvcmRlci1y
YWRpdXM6IDEycHg7CiAgICAgICAgICAgIGJveC1zaGFkb3c6CiAgICAgICAgICAg
ICAgICAwIDRweCA2cHggcmdiYSgzMCwgNDAsIDcwLCAuMDQpLAogICAgICAgICAg
ICAgICAgMCAxNHB4IDM2cHggcmdiYSgzMCwgNDAsIDcwLCAuMTYpOwogICAgICAg
ICAgICBjb2xvcjogdmFyKC0tdHh0KTsKICAgICAgICAgICAgcG9pbnRlci1ldmVu
dHM6IGF1dG87CiAgICAgICAgICAgIG9wYWNpdHk6IDA7CiAgICAgICAgICAgIHRy
YW5zZm9ybTogdHJhbnNsYXRlWSg0cHgpIHNjYWxlKC45OCk7CiAgICAgICAgICAg
IHRyYW5zaXRpb246IG9wYWNpdHkgLjE0cyBlYXNlLCB0cmFuc2Zvcm0gLjE0cyBl
YXNlOwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFw
cC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgfQogICAgICAgICNwYXRoLXRpcC5v
biB7CiAgICAgICAgICAgIGRpc3BsYXk6IGJsb2NrOwogICAgICAgICAgICBvcGFj
aXR5OiAxOwogICAgICAgICAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoMCkgc2Nh
bGUoMSk7CiAgICAgICAgfQogICAgICAgIC5wdC1oZWFkIHsKICAgICAgICAgICAg
ZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250
ZW50OiBzcGFjZS1iZXR3ZWVuOwogICAgICAgICAgICBnYXA6IDEwcHg7IHBhZGRp
bmc6IDEwcHggMTJweCA4cHg7CiAgICAgICAgICAgIGJvcmRlci1ib3R0b206IDFw
eCBzb2xpZCByZ2JhKDcwLCA4NCwgMTIwLCAuMDcpOwogICAgICAgIH0KICAgICAg
ICAucHQtdGl0bGUgewogICAgICAgICAgICBmb250LXNpemU6IDExcHg7IGZvbnQt
d2VpZ2h0OiA3MDA7IGxldHRlci1zcGFjaW5nOiAuMDRlbTsKICAgICAgICAgICAg
Y29sb3I6IHZhcigtLXR4dDIpOyB0ZXh0LXRyYW5zZm9ybTogdXBwZXJjYXNlOwog
ICAgICAgICAgICBmbGV4LXNocmluazogMDsKICAgICAgICB9CiAgICAgICAgLnB0
LWhlYWQtYnRuIHsKICAgICAgICAgICAgZmxleC1zaHJpbms6IDA7IG1hcmdpbi1s
ZWZ0OiBhdXRvOwogICAgICAgICAgICBoZWlnaHQ6IDIycHg7IHBhZGRpbmc6IDAg
OHB4OyBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsg
Z2FwOiA0cHg7CiAgICAgICAgICAgIGJvcmRlcjogMXB4IHNvbGlkIHJnYmEoMTA3
LDExMiwxMjgsLjIyKTsgYm9yZGVyLXJhZGl1czogNnB4OyBjdXJzb3I6IHBvaW50
ZXI7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoMTA3LDExMiwxMjgsLjA2
KTsgY29sb3I6ICM4YTkwYTA7IGZvbnQtc2l6ZTogMTFweDsgZm9udC13ZWlnaHQ6
IDYwMDsKICAgICAgICAgICAgd2hpdGUtc3BhY2U6IG5vd3JhcDsKICAgICAgICAg
ICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1k
cmFnOwogICAgICAgICAgICB0cmFuc2l0aW9uOiBiYWNrZ3JvdW5kIHZhcigtLXRy
KSwgY29sb3IgdmFyKC0tdHIpLCBib3JkZXItY29sb3IgdmFyKC0tdHIpOwogICAg
ICAgIH0KICAgICAgICAucHQtaGVhZC1idG46aG92ZXIgewogICAgICAgICAgICBi
YWNrZ3JvdW5kOiByZ2JhKDEwNywxMTIsMTI4LC4xMik7IGNvbG9yOiB2YXIoLS10
eHQyKTsKICAgICAgICAgICAgYm9yZGVyLWNvbG9yOiByZ2JhKDEwNywxMTIsMTI4
LC40KTsKICAgICAgICB9CiAgICAgICAgLnB0LWxpc3QgeyBwYWRkaW5nOiA2cHgg
OHB4IDhweDsgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsg
Z2FwOiA0cHg7IH0KICAgICAgICAucHQtcm93IHsKICAgICAgICAgICAgZGlzcGxh
eTogZ3JpZDsgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiA4cHggMWZyOyBnYXA6IDhw
eDsKICAgICAgICAgICAgcGFkZGluZzogOHB4IDhweDsgYm9yZGVyLXJhZGl1czog
OHB4OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDI1NSwyNTUsMjU1LC43
KTsKICAgICAgICB9CiAgICAgICAgLnB0LXJvdy5kZWFkIHsgYmFja2dyb3VuZDog
cmdiYSgyNTUsIDEyMywgMTU2LCAuMDYpOyB9CiAgICAgICAgLnB0LWRvdCB7CiAg
ICAgICAgICAgIHdpZHRoOiA4cHg7IGhlaWdodDogOHB4OyBib3JkZXItcmFkaXVz
OiA1MCU7IG1hcmdpbi10b3A6IDVweDsKICAgICAgICAgICAgYmFja2dyb3VuZDog
IzJlYjQ3ODsgYm94LXNoYWRvdzogMCAwIDAgM3B4IHJnYmEoNDYsIDE4MCwgMTIw
LCAuMTgpOwogICAgICAgIH0KICAgICAgICAucHQtcm93LmRlYWQgLnB0LWRvdCB7
CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNlODVhN2E7IGJveC1zaGFkb3c6IDAg
MCAwIDNweCByZ2JhKDIzMiwgOTAsIDEyMiwgLjE2KTsKICAgICAgICB9CiAgICAg
ICAgLnB0LW5hbWUgewogICAgICAgICAgICBmb250LXNpemU6IDEycHg7IGZvbnQt
d2VpZ2h0OiA2NTA7IGNvbG9yOiB2YXIoLS10eHQpOwogICAgICAgICAgICBsaW5l
LWhlaWdodDogMS4zOyB3b3JkLWJyZWFrOiBicmVhay1hbGw7CiAgICAgICAgfQog
ICAgICAgIC5wdC1wYXRoIHsKICAgICAgICAgICAgbWFyZ2luLXRvcDogM3B4Owog
ICAgICAgICAgICBmb250OiAxMC41cHgvMS40NSAnQ2FzY2FkaWEgTW9ubycsJ0Nv
bnNvbGFzJywnTWljcm9zb2Z0IFlhSGVpIFVJJyxtb25vc3BhY2U7CiAgICAgICAg
ICAgIGNvbG9yOiB2YXIoLS10eHQyKTsgd29yZC1icmVhazogYnJlYWstYWxsOwog
ICAgICAgICAgICB1c2VyLXNlbGVjdDogdGV4dDsKICAgICAgICB9CiAgICAgICAg
LnB0LXBhdGgubGl2ZSB7CiAgICAgICAgICAgIGNvbG9yOiB2YXIoLS1hY2MpOyBj
dXJzb3I6IHBvaW50ZXI7CiAgICAgICAgfQogICAgICAgIC5wdC1wYXRoLmxpdmU6
aG92ZXIgeyB0ZXh0LWRlY29yYXRpb246IHVuZGVybGluZTsgfQogICAgICAgIC5w
dC1wYXRoLmRlYWQgewogICAgICAgICAgICBjb2xvcjogI2M0M2Q1YzsKICAgICAg
ICAgICAgdGV4dC1kZWNvcmF0aW9uOiBsaW5lLXRocm91Z2g7CiAgICAgICAgICAg
IHRleHQtZGVjb3JhdGlvbi10aGlja25lc3M6IDJweDsKICAgICAgICAgICAgdGV4
dC1kZWNvcmF0aW9uLWNvbG9yOiAjZTExZDQ4OwogICAgICAgICAgICBjdXJzb3I6
IGRlZmF1bHQ7CiAgICAgICAgfQogICAgICAgIC5wdC1hY3Rpb25zIHsKICAgICAg
ICAgICAgbWFyZ2luLXRvcDogNnB4OwogICAgICAgICAgICBkaXNwbGF5OiBmbGV4
OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDZweDsgZmxleC13cmFwOiB3cmFw
OwogICAgICAgIH0KICAgICAgICAucHQtY29weS1idG4gewogICAgICAgICAgICBo
ZWlnaHQ6IDIycHg7IHBhZGRpbmc6IDAgOHB4OyBkaXNwbGF5OiBpbmxpbmUtZmxl
eDsgYWxpZ24taXRlbXM6IGNlbnRlcjsKICAgICAgICAgICAgYm9yZGVyOiAxcHgg
c29saWQgcmdiYSgxMDcsMTEyLDEyOCwuMjIpOyBib3JkZXItcmFkaXVzOiA2cHg7
IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICAgICAgYmFja2dyb3VuZDogcmdiYSgx
MDcsMTEyLDEyOCwuMDYpOyBjb2xvcjogIzhhOTBhMDsgZm9udC1zaXplOiAxMXB4
OyBmb250LXdlaWdodDogNjAwOwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdp
b246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgICAgIHRy
YW5zaXRpb246IGJhY2tncm91bmQgdmFyKC0tdHIpLCBjb2xvciB2YXIoLS10ciks
IGJvcmRlci1jb2xvciB2YXIoLS10cik7CiAgICAgICAgfQogICAgICAgIC5wdC1j
b3B5LWJ0bjpob3ZlciB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoMTA3
LDExMiwxMjgsLjEyKTsgY29sb3I6IHZhcigtLXR4dDIpOwogICAgICAgICAgICBi
b3JkZXItY29sb3I6IHJnYmEoMTA3LDExMiwxMjgsLjQpOwogICAgICAgIH0KICAg
ICAgICAucHQtY29weS1idG4ub2sgewogICAgICAgICAgICBjb2xvcjogIzFmN2E1
NTsgYm9yZGVyLWNvbG9yOiByZ2JhKDQ2LCAxODAsIDEyMCwgLjM1KTsKICAgICAg
ICAgICAgYmFja2dyb3VuZDogcmdiYSg0NiwgMTgwLCAxMjAsIC4xKTsKICAgICAg
ICB9CiAgICAgICAgLml0bS5pdC1ncm91cCB7CiAgICAgICAgICAgIGZsZXgtZGly
ZWN0aW9uOiBjb2x1bW47CiAgICAgICAgICAgIGFsaWduLWl0ZW1zOiBzdHJldGNo
OwogICAgICAgICAgICBnYXA6IDA7CiAgICAgICAgICAgIHBhZGRpbmc6IDZweCA4
cHggNHB4OwogICAgICAgICAgICBjdXJzb3I6IGRlZmF1bHQ7CiAgICAgICAgfQog
ICAgICAgIC5pdG0uaXQtZ3JvdXA6aG92ZXIgeyBiYWNrZ3JvdW5kOiB2YXIoLS1j
YXJkKTsgfQogICAgICAgIC5tZy1oZWFkIHsKICAgICAgICAgICAgZGlzcGxheTog
ZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA2cHg7CiAgICAgICAgICAg
IGZvbnQtc2l6ZTogMTFweDsgY29sb3I6IHZhcigtLXR4dDMpOyBmb250LXdlaWdo
dDogNjAwOwogICAgICAgICAgICBwYWRkaW5nOiAycHggMnB4IDZweDsgdXNlci1z
ZWxlY3Q6IG5vbmU7CiAgICAgICAgfQogICAgICAgIC5tZy1oZWFkIC5tZy10YWcg
ewogICAgICAgICAgICBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6
IGNlbnRlcjsKICAgICAgICAgICAgaGVpZ2h0OiAxNnB4OyBwYWRkaW5nOiAwIDZw
eDsgYm9yZGVyLXJhZGl1czogOHB4OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiBy
Z2JhKDkxLDExNSwyMzIsLjEyKTsgY29sb3I6IHZhcigtLWFjYyk7IGZvbnQtc2l6
ZTogMTBweDsKICAgICAgICB9CiAgICAgICAgLm1nLXJvdyB7CiAgICAgICAgICAg
IHBhZGRpbmc6IDdweCA2cHg7IG1hcmdpbi1ib3R0b206IDNweDsKICAgICAgICAg
ICAgYm9yZGVyLXJhZGl1czogNXB4OyBjdXJzb3I6IHBvaW50ZXI7CiAgICAgICAg
ICAgIGJvcmRlcjogMXB4IHNvbGlkIHRyYW5zcGFyZW50OwogICAgICAgICAgICB0
cmFuc2l0aW9uOiBiYWNrZ3JvdW5kIC4xMnMgZWFzZSwgYm9yZGVyLWNvbG9yIC4x
MnMgZWFzZTsKICAgICAgICB9CiAgICAgICAgLm1nLXJvdzpob3ZlciB7IGJhY2tn
cm91bmQ6IHZhcigtLWNhcmQtaCk7IH0KICAgICAgICAubWctcm93LnNlbCB7CiAg
ICAgICAgICAgIGJhY2tncm91bmQ6ICNlZGYxZmY7CiAgICAgICAgICAgIGJvcmRl
ci1jb2xvcjogcmdiYSg5MSwxMTUsMjMyLC4zNSk7CiAgICAgICAgICAgIGJveC1z
aGFkb3c6IDAgMCAwIDFweCByZ2JhKDkxLDExNSwyMzIsLjI1KTsKICAgICAgICB9
CiAgICAgICAgLm1nLXJvdy5tdWx0aSB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6
ICNlZWYyZmY7CiAgICAgICAgICAgIGJvcmRlci1jb2xvcjogcmdiYSg5MSwxMTUs
MjMyLC40NSk7CiAgICAgICAgfQogICAgICAgIC5tZy10aXRsZSB7CiAgICAgICAg
ICAgIGZvbnQtc2l6ZTogMTNweDsgZm9udC13ZWlnaHQ6IDYwMDsgY29sb3I6IHZh
cigtLWFjYyk7CiAgICAgICAgICAgIG1hcmdpbi1ib3R0b206IDJweDsgbGluZS1o
ZWlnaHQ6IDEuMzU7CiAgICAgICAgICAgIGRpc3BsYXk6IC13ZWJraXQtYm94OyAt
d2Via2l0LWJveC1vcmllbnQ6IHZlcnRpY2FsOyAtd2Via2l0LWxpbmUtY2xhbXA6
IDI7CiAgICAgICAgICAgIG92ZXJmbG93OiBoaWRkZW47IHdvcmQtYnJlYWs6IGJy
ZWFrLXdvcmQ7CiAgICAgICAgfQogICAgICAgIC5tZy1ib2R5IHsKICAgICAgICAg
ICAgZm9udC1zaXplOiAxMi41cHg7IGZvbnQtd2VpZ2h0OiA1MDA7IGNvbG9yOiB2
YXIoLS10eHQpOwogICAgICAgICAgICB3aGl0ZS1zcGFjZTogcHJlLXdyYXA7IHdv
cmQtYnJlYWs6IGJyZWFrLWFsbDsKICAgICAgICAgICAgZGlzcGxheTogLXdlYmtp
dC1ib3g7IC13ZWJraXQtYm94LW9yaWVudDogdmVydGljYWw7IC13ZWJraXQtbGlu
ZS1jbGFtcDogNDsKICAgICAgICAgICAgb3ZlcmZsb3c6IGhpZGRlbjsgbGluZS1o
ZWlnaHQ6IDEuNDsKICAgICAgICB9CiAgICAgICAgLm1nLWJvZHkuaW1nIHsgY29s
b3I6IHZhcigtLXR4dDIpOyB9CiAgICAgICAgLm1nLXJvdy10b3AgewogICAgICAg
ICAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogZmxleC1zdGFydDsgZ2Fw
OiA4cHg7CiAgICAgICAgfQogICAgICAgIC5tZy1yb3ctbWFpbiB7IGZsZXg6IDE7
IG1pbi13aWR0aDogMDsgfQogICAgICAgIC5tZy1zcmMgewogICAgICAgICAgICB3
aWR0aDogMThweDsgaGVpZ2h0OiAxOHB4OyBmbGV4LXNocmluazogMDsgbWFyZ2lu
LXRvcDogMnB4OwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiAzcHg7IG9iamVj
dC1maXQ6IGNvbnRhaW47CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoMCww
LDAsLjA0KTsKICAgICAgICB9CiAgICAgICAgI2FwcC53eC1uaWdodCAubWctcm93
LnNlbCB7IGJhY2tncm91bmQ6ICMyYTNhNjg7IGJvcmRlci1jb2xvcjogcmdiYSgx
NDAsMTY1LDI1NSwuNCk7IH0KICAgICAgICAjYXBwLnd4LW5pZ2h0IC5tZy1yb3cu
bXVsdGkgeyBiYWNrZ3JvdW5kOiAjMzE0Mjc4OyB9CiAgICAgICAgI2FwcC53eC1u
aWdodCAubWctcm93OmhvdmVyIHsgYmFja2dyb3VuZDogdmFyKC0tY2FyZC1oKTsg
fQogICAgICAgIC5pLWZhdi10aXRsZSB7CiAgICAgICAgICAgIGZvbnQtc2l6ZTog
MTNweDsgZm9udC13ZWlnaHQ6IDYwMDsgY29sb3I6IHZhcigtLWFjYyk7CiAgICAg
ICAgICAgIG1hcmdpbjogMCAwIDNweDsgbGluZS1oZWlnaHQ6IDEuMzU7CiAgICAg
ICAgICAgIGRpc3BsYXk6IC13ZWJraXQtYm94OyAtd2Via2l0LWJveC1vcmllbnQ6
IHZlcnRpY2FsOyAtd2Via2l0LWxpbmUtY2xhbXA6IDI7CiAgICAgICAgICAgIG92
ZXJmbG93OiBoaWRkZW47IHdvcmQtYnJlYWs6IGJyZWFrLXdvcmQ7CiAgICAgICAg
fQogICAgICAgICN0aXRsZS1kbGcgewogICAgICAgICAgICBkaXNwbGF5OiBub25l
OyBwb3NpdGlvbjogZml4ZWQ7IGluc2V0OiAwOyB6LWluZGV4OiAxMDA7CiAgICAg
ICAgICAgIGJhY2tncm91bmQ6IHJnYmEoMTUsMTgsMjgsLjM1KTsKICAgICAgICAg
ICAgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7
CiAgICAgICAgfQogICAgICAgICN0aXRsZS1kbGcub24geyBkaXNwbGF5OiBmbGV4
OyB9CiAgICAgICAgI3RpdGxlLWRsZyAudGl0bGUtYm94IHsKICAgICAgICAgICAg
d2lkdGg6IDI2MHB4OyBwYWRkaW5nOiAxNnB4IDE2cHggMTJweDsKICAgICAgICAg
ICAgYmFja2dyb3VuZDogdmFyKC0tY2FyZCk7IGJvcmRlci1yYWRpdXM6IDEwcHg7
CiAgICAgICAgICAgIGJveC1zaGFkb3c6IDAgOHB4IDI4cHggcmdiYSgwLDAsMCwu
MTgpOwogICAgICAgIH0KICAgICAgICAjdGl0bGUtaW5wdXQgewogICAgICAgICAg
ICB3aWR0aDogMTAwJTsgYm94LXNpemluZzogYm9yZGVyLWJveDsgbWFyZ2luOiA4
cHggMCAxMnB4OwogICAgICAgICAgICBoZWlnaHQ6IDMycHg7IHBhZGRpbmc6IDAg
MTBweDsgYm9yZGVyLXJhZGl1czogNnB4OwogICAgICAgICAgICBib3JkZXI6IDFw
eCBzb2xpZCAjZDVkYWU2OyBiYWNrZ3JvdW5kOiAjZmZmOyBjb2xvcjogdmFyKC0t
dHh0KTsKICAgICAgICAgICAgZm9udC1zaXplOiAxM3B4OyBvdXRsaW5lOiBub25l
OwogICAgICAgIH0KICAgICAgICAjdGl0bGUtaW5wdXQ6Zm9jdXMgeyBib3JkZXIt
Y29sb3I6IHZhcigtLWFjYyk7IH0KICAgIDwvc3R5bGU+CjwvaGVhZD4KPGJvZHk+
CjxkaXYgaWQ9ImFwcCI+CiAgICA8ZGl2IGlkPSJ3eC1zdGFycyIgYXJpYS1oaWRk
ZW49InRydWUiPjwvZGl2PgogICAgPGRpdiBpZD0id3gtbW9vbiIgYXJpYS1oaWRk
ZW49InRydWUiPvCfjJk8L2Rpdj4KICAgIDxkaXYgaWQ9ImhkciI+CiAgICAgICAg
PGRpdiBpZD0iaGVhcnQiPgogICAgICAgICAgICA8c3ZnIHZpZXdCb3g9IjAgMCAy
NCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13
aWR0aD0iMS44IgogICAgICAgICAgICAgICAgIHN0cm9rZS1saW5lY2FwPSJyb3Vu
ZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI+CiAgICAgICAgICAgICAgICA8cmVj
dCB4PSI5IiB5PSIyIiB3aWR0aD0iNiIgaGVpZ2h0PSI0IiByeD0iMSIvPgogICAg
ICAgICAgICAgICAgPHBhdGggZD0iTTE2IDRoMmEyIDIgMCAwIDEgMiAydjE0YTIg
MiAwIDAgMS0yIDJINmEyIDIgMCAwIDEtMi0yVjZhMiAyIDAgMCAxIDItMmgyIi8+
CiAgICAgICAgICAgICAgICA8cGF0aCBkPSJNOSAxMmg2TTkgMTZoNCIvPgogICAg
ICAgICAgICA8L3N2Zz4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGlkPSJo
ZHItZ3JvdyI+PC9kaXY+CiAgICAgICAgPGJ1dHRvbiBpZD0iYnRuLWxvY2F0ZSIg
dHlwZT0iYnV0dG9uIiB0aXRsZT0i5a6a5L2N5Yiw5LiK5qyh5L2/55So55qE5p2h
55uuIiBkaXNhYmxlZD4KICAgICAgICAgICAgPHN2ZyB2aWV3Qm94PSIwIDAgMjQg
MjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lk
dGg9IjIiCiAgICAgICAgICAgICAgICAgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBz
dHJva2UtbGluZWpvaW49InJvdW5kIj4KICAgICAgICAgICAgICAgIDxjaXJjbGUg
Y3g9IjEyIiBjeT0iMTIiIHI9IjgiLz4KICAgICAgICAgICAgICAgIDxjaXJjbGUg
Y3g9IjEyIiBjeT0iMTIiIHI9IjMuNSIvPgogICAgICAgICAgICA8L3N2Zz4KICAg
ICAgICA8L2J1dHRvbj4KICAgICAgICA8ZGl2IGlkPSJzZWFyY2gtd3JhcCI+CiAg
ICAgICAgICAgIDxidXR0b24gaWQ9ImJ0bi1zZWFyY2giIHR5cGU9ImJ1dHRvbiIg
dGl0bGU9IuaQnOe0oiI+CiAgICAgICAgICAgICAgICA8c3ZnIHZpZXdCb3g9IjAg
MCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9r
ZS13aWR0aD0iMiIKICAgICAgICAgICAgICAgICAgICAgc3Ryb2tlLWxpbmVjYXA9
InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIj4KICAgICAgICAgICAgICAg
ICAgICA8Y2lyY2xlIGN4PSIxMSIgY3k9IjExIiByPSI3Ii8+CiAgICAgICAgICAg
ICAgICAgICAgPHBhdGggZD0iTTIwIDIwbC0zLjUtMy41Ii8+CiAgICAgICAgICAg
ICAgICA8L3N2Zz4KICAgICAgICAgICAgPC9idXR0b24+CiAgICAgICAgICAgIDxk
aXYgaWQ9InNlYXJjaC1ib3giPgogICAgICAgICAgICAgICAgPGJ1dHRvbiBpZD0i
YnRuLXRvZGF5IiB0eXBlPSJidXR0b24iPuW9k+WkqTwvYnV0dG9uPgogICAgICAg
ICAgICAgICAgPGlucHV0IGlkPSJzZWFyY2giIHR5cGU9InRleHQiIHBsYWNlaG9s
ZGVyPSLmkJzntKIuLi4iIGF1dG9jb21wbGV0ZT0ib2ZmIiBzcGVsbGNoZWNrPSJm
YWxzZSI+CiAgICAgICAgICAgICAgICA8YnV0dG9uIGlkPSJzZWFyY2gtY2xyIiB0
eXBlPSJidXR0b24iPuKclTwvYnV0dG9uPgogICAgICAgICAgICA8L2Rpdj4KICAg
ICAgICA8L2Rpdj4KICAgICAgICA8YnV0dG9uIGlkPSJidG4tcGluIiB0eXBlPSJi
dXR0b24iIHRpdGxlPSLpkonlnKjlsY/luZXkuIoiPgogICAgICAgICAgICA8c3Zn
IHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50
Q29sb3IiIHN0cm9rZS13aWR0aD0iMiIKICAgICAgICAgICAgICAgICBzdHJva2Ut
bGluZWpvaW49InJvdW5kIiBzdHJva2UtbGluZWNhcD0icm91bmQiPgogICAgICAg
ICAgICAgICAgPGxpbmUgeDE9IjEyIiB5MT0iMTciIHgyPSIxMiIgeTI9IjIyIi8+
CiAgICAgICAgICAgICAgICA8cGF0aCBkPSJNNSAxN2gxNHYtMS43NmEyIDIgMCAw
IDAtMS4xMS0xLjc5bC0xLjc4LS45QTIgMiAwIDAgMSAxNSAxMC43NlY2aDFhMiAy
IDAgMCAwIDAtNEg4YTIgMiAwIDAgMCAwIDRoMXY0Ljc2YTIgMiAwIDAgMS0xLjEx
IDEuNzlsLTEuNzguOUEyIDIgMCAwIDAgNSAxNS4yNFoiLz4KICAgICAgICAgICAg
PC9zdmc+CiAgICAgICAgPC9idXR0b24+CiAgICA8L2Rpdj4KCiAgICA8ZGl2IGlk
PSJ0YWJzIj4KICAgICAgICA8ZGl2IGNsYXNzPSJ0YWIgb24iIGRhdGEtdGFiPSJh
bGwiPuWFqOmDqDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InRhYiIgZGF0YS10
YWI9InRleHQiPuaWh+acrDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InRhYiIg
ZGF0YS10YWI9ImltYWdlIj7lm77lg488L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNz
PSJ0YWIiIGRhdGEtdGFiPSJmaWxlIj7mlofku7Y8L2Rpdj4KICAgICAgICA8ZGl2
IGNsYXNzPSJ0YWIiIGRhdGEtdGFiPSJsaW5rIj7pk77mjqU8L2Rpdj4KICAgICAg
ICA8ZGl2IGNsYXNzPSJ0YWIiIGRhdGEtdGFiPSJwaW5uZWQiPuaUtuiXjyA8c3Bh
biBjbGFzcz0iYmFkZ2UiIGlkPSJwaW4tY250IiBzdHlsZT0iZGlzcGxheTpub25l
Ij4wPC9zcGFuPjwvZGl2PgogICAgICAgIDxkaXYgaWQ9InRhYi1hY3Rpb25zIj4K
ICAgICAgICAgICAgPGJ1dHRvbiBpZD0ibXVsdGktY250IiB0eXBlPSJidXR0b24i
IHRpdGxlPSLlj5bmtojlpJrpgIkiPuW3sumAiSAwPC9idXR0b24+CiAgICAgICAg
ICAgIDxzcGFuIGlkPSJiYXItdHh0Ij4wPC9zcGFuPgogICAgICAgICAgICA8YnV0
dG9uIGlkPSJidG4tY2xyIiB0eXBlPSJidXR0b24iIHRpdGxlPSLmuIXnqbrljobl
j7IiPgogICAgICAgICAgICAgICAgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZp
bGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIi
CiAgICAgICAgICAgICAgICAgICAgIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ry
b2tlLWxpbmVqb2luPSJyb3VuZCI+CiAgICAgICAgICAgICAgICAgICAgPHBvbHls
aW5lIHBvaW50cz0iMyA2IDUgNiAyMSA2Ii8+CiAgICAgICAgICAgICAgICAgICAg
PHBhdGggZD0iTTE5IDZsLTEgMTRhMiAyIDAgMCAxLTIgMkg4YTIgMiAwIDAgMS0y
LTJMNSA2Ii8+CiAgICAgICAgICAgICAgICAgICAgPHBhdGggZD0iTTEwIDExdjZN
MTQgMTF2Nk05IDZWNGg2djIiLz4KICAgICAgICAgICAgICAgIDwvc3ZnPgogICAg
ICAgICAgICA8L2J1dHRvbj4KICAgICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAg
IDxkaXYgaWQ9Imxpc3QiPgogICAgICAgIDxkaXYgaWQ9ImVtcHR5IiBjbGFzcz0i
b24iPgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJlLWljbyIgYXJpYS1oaWRkZW49
InRydWUiPgogICAgICAgICAgICAgICAgPHN2ZyB2aWV3Qm94PSIwIDAgNjQgNjQi
IGZpbGw9Im5vbmUiPgogICAgICAgICAgICAgICAgICAgIDxyZWN0IHg9IjE0IiB5
PSIxMiIgd2lkdGg9IjM2IiBoZWlnaHQ9IjQ0IiByeD0iOCIgZmlsbD0iIzVCNzNF
OCIgb3BhY2l0eT0iLjE4Ii8+CiAgICAgICAgICAgICAgICAgICAgPHJlY3QgeD0i
MTgiIHk9IjE2IiB3aWR0aD0iMjgiIGhlaWdodD0iMzYiIHJ4PSI2IiBmaWxsPSIj
ZmZmIiBzdHJva2U9IiM1QjczRTgiIHN0cm9rZS13aWR0aD0iMiIvPgogICAgICAg
ICAgICAgICAgICAgIDxyZWN0IHg9IjI0IiB5PSIxMCIgd2lkdGg9IjE2IiBoZWln
aHQ9IjEwIiByeD0iMyIgZmlsbD0iIzVCNzNFOCIvPgogICAgICAgICAgICAgICAg
ICAgIDxyZWN0IHg9IjI4IiB5PSIxMiIgd2lkdGg9IjgiIGhlaWdodD0iNiIgcng9
IjIiIGZpbGw9IiNFRUYxRjYiLz4KICAgICAgICAgICAgICAgICAgICA8cGF0aCBk
PSJNMjYgMzBoMTJNMjYgMzZoMTJNMjYgNDJoOCIgc3Ryb2tlPSIjQjhDMEQ5IiBz
dHJva2Utd2lkdGg9IjIuMiIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+CiAgICAg
ICAgICAgICAgICAgICAgPGNpcmNsZSBjeD0iNDgiIGN5PSIyMCIgcj0iMyIgZmls
bD0iI0ZGQjRDOCIvPgogICAgICAgICAgICAgICAgICAgIDxjaXJjbGUgY3g9IjEy
IiBjeT0iMjgiIHI9IjIuMiIgZmlsbD0iI0ZGRDU2QSIvPgogICAgICAgICAgICAg
ICAgPC9zdmc+CiAgICAgICAgICAgIDwvZGl2PgogICAgICAgICAgICA8ZGl2IGNs
YXNzPSJlLXR4dCIgaWQ9ImVtcHR5LXR4dCI+5pqC5peg6K6w5b2V77yM5aSN5Yi2
5ZCO6Ieq5Yqo5Ye6546wPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICA8L2Rpdj4K
ICAgIDxidXR0b24gaWQ9ImJ0bi10b3AiIHR5cGU9ImJ1dHRvbiIgdGl0bGU9IuWb
nuWIsOmhtumDqCIgYXJpYS1sYWJlbD0i5Zue5Yiw6aG26YOoIj4KICAgICAgICA8
c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJy
ZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMi4yIgogICAgICAgICAgICAgc3Ryb2tl
LWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIj4KICAgICAg
ICAgICAgPHBhdGggZD0iTTEyIDE5VjUiLz4KICAgICAgICAgICAgPHBhdGggZD0i
TTUgMTJsNy03IDcgNyIvPgogICAgICAgIDwvc3ZnPgogICAgPC9idXR0b24+Cjwv
ZGl2PgoKPGRpdiBpZD0iY3R4Ij4KICAgIDxkaXYgY2xhc3M9ImMtaXRlbSIgaWQ9
ImMtY29weSI+PHNwYW4gY2xhc3M9ImMtaWNvIj7ijpg8L3NwYW4+5aSN5Yi2PC9k
aXY+CiAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0iIGlkPSJjLXBhc3RlIj48c3BhbiBj
bGFzcz0iYy1pY28iPuKPjjwvc3Bhbj7nspjotLQ8L2Rpdj4KICAgIDxkaXYgY2xh
c3M9ImMtc2VwIj48L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImMtaXRlbSIgaWQ9ImMt
cGluIj48c3BhbiBjbGFzcz0iYy1pY28iPuKYhTwvc3Bhbj7mlLbol488L2Rpdj4K
ICAgIDxkaXYgY2xhc3M9ImMtaXRlbSIgaWQ9ImMtdGl0bGUiIHN0eWxlPSJkaXNw
bGF5Om5vbmUiPjxzcGFuIGNsYXNzPSJjLWljbyI+4pyOPC9zcGFuPuiuvue9ruag
h+mimDwvZGl2PgogICAgPGRpdiBjbGFzcz0iYy1pdGVtIiBpZD0iYy1tZXJnZSIg
c3R5bGU9ImRpc3BsYXk6bm9uZSI+PHNwYW4gY2xhc3M9ImMtaWNvIj7ip4k8L3Nw
YW4+5ZCI5bm2PC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0iIGlkPSJjLXVu
bWVyZ2UiIHN0eWxlPSJkaXNwbGF5Om5vbmUiPjxzcGFuIGNsYXNzPSJjLWljbyI+
4oeEPC9zcGFuPuWPlua2iOWQiOW5tjwvZGl2PgogICAgPGRpdiBjbGFzcz0iYy1p
dGVtIiBpZD0iYy10b3AiPjxzcGFuIGNsYXNzPSJjLWljbyI+4oaRPC9zcGFuPuen
u+WIsOmhtumDqDwvZGl2PgogICAgPGRpdiBjbGFzcz0iYy1pdGVtIiBpZD0iYy1j
bGVhci1wYXN0ZWQiIHN0eWxlPSJkaXNwbGF5Om5vbmUiPjxzcGFuIGNsYXNzPSJj
LWljbyI+4pyTPC9zcGFuPua4hemZpOeKtuaAgTwvZGl2PgogICAgPGRpdiBjbGFz
cz0iYy1zZXAiPjwvZGl2PgogICAgPGRpdiBjbGFzcz0iYy1pdGVtIGRhbmdlciIg
aWQ9ImMtZGVsIj48c3BhbiBjbGFzcz0iYy1pY28iPuKclTwvc3Bhbj7liKDpmaQ8
L2Rpdj4KPC9kaXY+Cgo8ZGl2IGlkPSJjbHItZGxnIj4KICAgIDxkaXYgY2xhc3M9
ImNsci1ib3giIHJvbGU9ImRpYWxvZyIgYXJpYS1tb2RhbD0idHJ1ZSI+CiAgICAg
ICAgPGRpdiBjbGFzcz0iY2xyLXRpdGxlIiBpZD0iY2xyLXRpdGxlIj7noa7orqTm
uIXnqbrvvJ88L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJjbHItZGVzYyIgaWQ9
ImNsci1kZXNjIj7pu5jorqTku4XmuIXnqbrlvZPlpKnlhoXlrrnjgII8L2Rpdj4K
ICAgICAgICA8bGFiZWwgY2xhc3M9ImNsci1jaGVjayIgZm9yPSJjbHItYWxsIj4K
ICAgICAgICAgICAgPGlucHV0IHR5cGU9ImNoZWNrYm94IiBpZD0iY2xyLWFsbCI+
CiAgICAgICAgICAgIDxzcGFuPua4heepuuaJgOaciTwvc3Bhbj4KICAgICAgICA8
L2xhYmVsPgogICAgICAgIDxkaXYgY2xhc3M9ImNsci1idG5zIj4KICAgICAgICAg
ICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGlkPSJjbHItY2FuY2VsIj7lj5bmtog8
L2J1dHRvbj4KICAgICAgICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGlkPSJj
bHItb2siPua4heepujwvYnV0dG9uPgogICAgICAgIDwvZGl2PgogICAgPC9kaXY+
CjwvZGl2PgoKPGRpdiBpZD0idGl0bGUtZGxnIj4KICAgIDxkaXYgY2xhc3M9InRp
dGxlLWJveCIgcm9sZT0iZGlhbG9nIiBhcmlhLW1vZGFsPSJ0cnVlIj4KICAgICAg
ICA8ZGl2IGNsYXNzPSJjbHItdGl0bGUiPuiuvue9ruagh+mimDwvZGl2PgogICAg
ICAgIDxkaXYgY2xhc3M9ImNsci1kZXNjIj7moIfpopjlj6/ooqvmkJzntKLmib7l
iLDvvIzku4XnlKjkuo7mlLbol4/mlbTnkIbjgII8L2Rpdj4KICAgICAgICA8aW5w
dXQgaWQ9InRpdGxlLWlucHV0IiB0eXBlPSJ0ZXh0IiBtYXhsZW5ndGg9IjgwIiBw
bGFjZWhvbGRlcj0i57uZ6L+Z5p2h5pS26JeP6LW35Liq5ZCN5a2X4oCmIiBhdXRv
Y29tcGxldGU9Im9mZiIgc3BlbGxjaGVjaz0iZmFsc2UiPgogICAgICAgIDxkaXYg
Y2xhc3M9ImNsci1idG5zIj4KICAgICAgICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0
b24iIGlkPSJ0aXRsZS1jYW5jZWwiPuWPlua2iDwvYnV0dG9uPgogICAgICAgICAg
ICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgaWQ9InRpdGxlLW9rIj7kv53lrZg8L2J1
dHRvbj4KICAgICAgICA8L2Rpdj4KICAgIDwvZGl2Pgo8L2Rpdj4KPGRpdiBpZD0i
cGF0aC10aXAiIGFyaWEtaGlkZGVuPSJ0cnVlIj48L2Rpdj4KCjxzY3JpcHQ+CiAg
ICBsZXQgYWxsQ2xpcHMgPSBbXSwgY3VyVGFiID0gJ2FsbCcsIHF1ZXJ5ID0gJycs
IGN0eENsaXAgPSBudWxsLCBzZWxlY3RlZElkID0gMCwgcGlubmVkVUkgPSBmYWxz
ZTsKICAgIGxldCBtdWx0aUlkcyA9IFtdOwogICAgbGV0IHRvZGF5T25seSA9IGZh
bHNlOwogICAgbGV0IGRpc2tUb3RhbCA9IDA7CiAgICBsZXQgbG9hZGluZ01vcmUg
PSBmYWxzZTsKICAgIGxldCBsaW5rTG9hZEFjdGl2ZSA9IGZhbHNlOwogICAgbGV0
IGxpbmtPYnNlcnZlcnMgPSBbXTsKICAgIC8vIE9wZW4gcGFuZWwgd2l0aG91dCBw
YXN0aW5nIOKGkiBhbHdheXMgbGFuZCBvbiBmaXJzdCBpdGVtIChhZnRlciBkYXRh
IGFycml2ZXMpCiAgICBsZXQgc2VsZWN0Rmlyc3RPblNob3cgPSBmYWxzZTsKICAg
IGxldCBsYXN0UGFzdGVJZCA9IDA7CiAgICBsZXQgbGFzdFBhc3RlVGFiID0gJ2Fs
bCc7CiAgICBsZXQgbG9jYXRlQWN0aXZlID0gZmFsc2U7CiAgICB0cnkgeyBsYXN0
UGFzdGVJZCA9ICtsb2NhbFN0b3JhZ2UuZ2V0SXRlbSgnY2xpcExhc3RQYXN0ZUlk
JykgfHwgMDsgfSBjYXRjaCB7fQogICAgdHJ5IHsKICAgICAgICBjb25zdCB0ID0g
bG9jYWxTdG9yYWdlLmdldEl0ZW0oJ2NsaXBMYXN0UGFzdGVUYWInKSB8fCAnYWxs
JzsKICAgICAgICBsYXN0UGFzdGVUYWIgPSBbJ2FsbCcsJ3RleHQnLCdpbWFnZScs
J2ZpbGUnLCdsaW5rJywncGlubmVkJ10uaW5jbHVkZXModCkgPyB0IDogJ2FsbCc7
CiAgICB9IGNhdGNoIHt9CiAgICAvLyBTYW1lLW9yaWdpbiB1bmRlciBjbGlwdWku
bG9jYWwgKEFQUF9IT1NUIOKGkiBDTElQX1YxX0RJUikuIENyb3NzLWhvc3QgY2xp
cHMuc3RvcmUgaXMgdW5yZWxpYWJsZS4KICAgIGNvbnN0IFNUT1JFX0JBU0UgPSAo
bG9jYXRpb24ub3JpZ2luICYmIGxvY2F0aW9uLm9yaWdpbi5pbmRleE9mKCdodHRw
czovLycpID09PSAwKQogICAgICAgID8gKGxvY2F0aW9uLm9yaWdpbi5yZXBsYWNl
KC9cLyQvLCAnJykgKyAnL2NsaXBzX3N0b3JlLycpCiAgICAgICAgOiAnaHR0cHM6
Ly9jbGlwdWkubG9jYWwvY2xpcHNfc3RvcmUvJzsKICAgIGZ1bmN0aW9uIG1ldGFD
ZW50ZXJIdG1sKGV4cGFuZElubmVyKSB7CiAgICAgICAgaWYgKGV4cGFuZElubmVy
ID09IG51bGwgfHwgZXhwYW5kSW5uZXIgPT09IGZhbHNlKQogICAgICAgICAgICBy
ZXR1cm4gYDxzcGFuIGNsYXNzPSJpLW1ldGEtY2VudGVyIj48L3NwYW4+YDsKICAg
ICAgICByZXR1cm4gYDxzcGFuIGNsYXNzPSJpLW1ldGEtY2VudGVyIj48YnV0dG9u
IGNsYXNzPSJpLWV4cGFuZC1idG4ke2V4cGFuZElubmVyLm9uID8gJyBvbicgOiAn
J30iIHR5cGU9ImJ1dHRvbiIgdGl0bGU9IuWxleW8gC/mlLbotbciPiR7ZXhwYW5k
SW5uZXIuaHRtbH08L2J1dHRvbj48L3NwYW4+YDsKICAgIH0KCiAgICBmdW5jdGlv
biByZW1lbWJlckxhc3RQYXN0ZShpZCkgewogICAgICAgIGxhc3RQYXN0ZUlkID0g
K2lkIHx8IDA7CiAgICAgICAgbGFzdFBhc3RlVGFiID0gY3VyVGFiIHx8ICdhbGwn
OwogICAgICAgIHRyeSB7CiAgICAgICAgICAgIGxvY2FsU3RvcmFnZS5zZXRJdGVt
KCdjbGlwTGFzdFBhc3RlSWQnLCBTdHJpbmcobGFzdFBhc3RlSWQpKTsKICAgICAg
ICAgICAgbG9jYWxTdG9yYWdlLnNldEl0ZW0oJ2NsaXBMYXN0UGFzdGVUYWInLCBs
YXN0UGFzdGVUYWIpOwogICAgICAgIH0gY2F0Y2gge30KICAgICAgICB1cGRhdGVM
b2NhdGVCdG4oKTsKICAgIH0KICAgIGZ1bmN0aW9uIHVwZGF0ZUxvY2F0ZUJ0bigp
IHsKICAgICAgICBjb25zdCBidG4gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgn
YnRuLWxvY2F0ZScpOwogICAgICAgIGlmICghYnRuKSByZXR1cm47CiAgICAgICAg
YnRuLmRpc2FibGVkID0gIWxhc3RQYXN0ZUlkOwogICAgICAgIGJ0bi5jbGFzc0xp
c3QudG9nZ2xlKCdoYXMtdGFyZ2V0JywgISFsYXN0UGFzdGVJZCk7CiAgICAgICAg
YnRuLmNsYXNzTGlzdC50b2dnbGUoJ29uJywgbG9jYXRlQWN0aXZlICYmICEhbGFz
dFBhc3RlSWQpOwogICAgICAgIGJ0bi50aXRsZSA9ICFsYXN0UGFzdGVJZAogICAg
ICAgICAgICA/ICfmmoLml6DkuIrmrKHkvb/nlKjkvY3nva4nCiAgICAgICAgICAg
IDogKGxvY2F0ZUFjdGl2ZSA/ICflj5bmtojlrprkvY3vvIzlm57liLDnrKzkuIDm
naEnIDogJ+WumuS9jeWIsOS4iuasoeS9v+eUqOeahOadoeebricpOwogICAgfQog
ICAgZnVuY3Rpb24gc2VsZWN0Rmlyc3RJdGVtKCkgewogICAgICAgIGxvY2F0ZUFj
dGl2ZSA9IGZhbHNlOwogICAgICAgIHdpbmRvdy5fX3BlbmRpbmdKdW1wSWQgPSAw
OwogICAgICAgIHdpbmRvdy5fX2p1bXBMb2FkVHJpZXMgPSAwOwogICAgICAgIHNl
bGVjdEZpcnN0T25TaG93ID0gZmFsc2U7CiAgICAgICAgY29uc3QgdmlzID0gdmlz
aWJsZUxpc3QoKTsKICAgICAgICBpZiAoIXZpcy5sZW5ndGgpIHsKICAgICAgICAg
ICAgc2VsZWN0ZWRJZCA9IDA7CiAgICAgICAgICAgIHN5bmNJdGVtSGlnaGxpZ2h0
KCk7CiAgICAgICAgICAgIHVwZGF0ZUxvY2F0ZUJ0bigpOwogICAgICAgICAgICBy
ZXR1cm47CiAgICAgICAgfQogICAgICAgIHNlbGVjdGVkSWQgPSB2aXNbMF0uaWQ7
CiAgICAgICAgbGlzdEVsLnNjcm9sbFRvcCA9IDA7CiAgICAgICAgc3luY0l0ZW1I
aWdobGlnaHQoKTsKICAgICAgICBjb25zdCBlbCA9IGxpc3RFbC5xdWVyeVNlbGVj
dG9yKCcuaXRtW2RhdGEtaWQ9IicgKyBzZWxlY3RlZElkICsgJyJdJyk7CiAgICAg
ICAgaWYgKGVsKSBlbC5zY3JvbGxJbnRvVmlldyh7IGJsb2NrOiAnbmVhcmVzdCcg
fSk7CiAgICAgICAgdXBkYXRlTG9jYXRlQnRuKCk7CiAgICB9CiAgICBmdW5jdGlv
biBqdW1wVG9MYXN0UGFzdGUoKSB7CiAgICAgICAgaWYgKCFsYXN0UGFzdGVJZCkg
cmV0dXJuOwogICAgICAgIC8vIEFscmVhZHkgbG9jYXRlZCBvbiBsYXN0IHBhc3Rl
IOKGkiBjYW5jZWwgYW5kIHNlbGVjdCBmaXJzdAogICAgICAgIGlmIChsb2NhdGVB
Y3RpdmUgJiYgK3NlbGVjdGVkSWQgPT09ICtsYXN0UGFzdGVJZCkgewogICAgICAg
ICAgICBzZWxlY3RGaXJzdEl0ZW0oKTsKICAgICAgICAgICAgcmV0dXJuOwogICAg
ICAgIH0KICAgICAgICBsb2NhdGVBY3RpdmUgPSB0cnVlOwogICAgICAgIHNlbGVj
dEZpcnN0T25TaG93ID0gZmFsc2U7CiAgICAgICAgc3RvcExpbmtNZWRpYSgpOwog
ICAgICAgIC8vIENsZWFyIGZpbHRlcnMgc28gdGhlIGl0ZW0gaXMgZmluZGFibGUg
b24gdGhlIHRhYiB3aGVyZSBpdCB3YXMgdXNlZAogICAgICAgIHF1ZXJ5ID0gJyc7
CiAgICAgICAgdG9kYXlPbmx5ID0gZmFsc2U7CiAgICAgICAgdHJ5IHsKICAgICAg
ICAgICAgY29uc3Qgc3JjaCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFy
Y2gnKTsKICAgICAgICAgICAgY29uc3Qgc2NsciA9IGRvY3VtZW50LmdldEVsZW1l
bnRCeUlkKCdzZWFyY2gtY2xyJyk7CiAgICAgICAgICAgIGNvbnN0IHdyYXAgPSBk
b2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLXdyYXAnKTsKICAgICAgICAg
ICAgY29uc3QgYnRuVG9kYXkgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRu
LXRvZGF5Jyk7CiAgICAgICAgICAgIGlmIChzcmNoKSB7IHNyY2gudmFsdWUgPSAn
Jzsgc3JjaC5jbGFzc0xpc3QucmVtb3ZlKCdoYXMtdmFsJyk7IH0KICAgICAgICAg
ICAgaWYgKHNjbHIpIHNjbHIuc3R5bGUuZGlzcGxheSA9ICdub25lJzsKICAgICAg
ICAgICAgaWYgKHdyYXApIHdyYXAuY2xhc3NMaXN0LnJlbW92ZSgnb3BlbicpOwog
ICAgICAgICAgICBpZiAoYnRuVG9kYXkpIGJ0blRvZGF5LmNsYXNzTGlzdC5yZW1v
dmUoJ29uJyk7CiAgICAgICAgfSBjYXRjaCB7fQogICAgICAgIGNvbnN0IHRhYiA9
IFsnYWxsJywndGV4dCcsJ2ltYWdlJywnZmlsZScsJ2xpbmsnLCdwaW5uZWQnXS5p
bmNsdWRlcyhsYXN0UGFzdGVUYWIpCiAgICAgICAgICAgID8gbGFzdFBhc3RlVGFi
IDogJ2FsbCc7CiAgICAgICAgY29uc3QgcHJldlRhYiA9IGN1clRhYjsKICAgICAg
ICBjdXJUYWIgPSB0YWI7CiAgICAgICAgbGlua0xvYWRBY3RpdmUgPSAodGFiID09
PSAnbGluaycpOwogICAgICAgIGxvYWRpbmdNb3JlID0gZmFsc2U7CiAgICAgICAg
ZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLnRhYicpLmZvckVhY2goZWwgPT4K
ICAgICAgICAgICAgZWwuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCBlbC5kYXRhc2V0
LnRhYiA9PT0gdGFiKSk7CiAgICAgICAgaWYgKHByZXZUYWIgPT09ICdsaW5rJyAm
JiB0YWIgIT09ICdsaW5rJykKICAgICAgICAgICAgc3RvcExpbmtNZWRpYSgpOwog
ICAgICAgIGNsZWFyTXVsdGkoKTsKICAgICAgICBzZWxlY3RlZElkID0gbGFzdFBh
c3RlSWQ7CiAgICAgICAgd2luZG93Ll9fcGVuZGluZ0p1bXBJZCA9IGxhc3RQYXN0
ZUlkOwogICAgICAgIHdpbmRvdy5fX2p1bXBMb2FkVHJpZXMgPSAwOwogICAgICAg
IHdpbmRvdy5fX2p1bXBGZWxsQmFjayA9IGZhbHNlOwogICAgICAgIHVwZGF0ZUxv
Y2F0ZUJ0bigpOwogICAgICAgIHJlcXVlc3RWaWV3KCk7CiAgICB9CgogICAgZnVu
Y3Rpb24gcmVxdWVzdFZpZXcoKSB7CiAgICAgICAgYWhrKCdzZXRWaWV3JywgY3Vy
VGFiLCBxdWVyeSwgdG9kYXlPbmx5ID8gJzEnIDogJzAnKTsKICAgIH0KICAgIGZ1
bmN0aW9uIHJlcXVlc3RNb3JlKCkgewogICAgICAgIGlmIChsb2FkaW5nTW9yZSkg
cmV0dXJuOwogICAgICAgIGlmIChhbGxDbGlwcy5sZW5ndGggPj0gZGlza1RvdGFs
KSByZXR1cm47CiAgICAgICAgbG9hZGluZ01vcmUgPSB0cnVlOwogICAgICAgIGFo
aygnbG9hZE1vcmUnKTsKICAgIH0KCiAgICBmdW5jdGlvbiBob3N0T2YodXJsKSB7
CiAgICAgICAgdHJ5IHsgcmV0dXJuIG5ldyBVUkwodXJsKS5ob3N0bmFtZTsgfSBj
YXRjaCB7IHJldHVybiAnJzsgfQogICAgfQogICAgZnVuY3Rpb24gZmF2aWNvblVy
bChob3N0KSB7CiAgICAgICAgaWYgKCFob3N0KSByZXR1cm4gJyc7CiAgICAgICAg
Ly8gRHVja0R1Y2tHbyBpY29ucyBhcmUgbW9yZSByZWFjaGFibGUgdGhhbiBHb29n
bGUgczIgaW4gbWFueSBuZXR3b3JrcwogICAgICAgIHJldHVybiAnaHR0cHM6Ly9p
Y29ucy5kdWNrZHVja2dvLmNvbS9pcDMvJyArIGVuY29kZVVSSUNvbXBvbmVudCho
b3N0KSArICcuaWNvJzsKICAgIH0KICAgIGZ1bmN0aW9uIHNob3RVcmwodXJsKSB7
CiAgICAgICAgLy8gUHJlZmVyIHRodW0uaW8g4oCUIFdvcmRQcmVzcyBtc2hvdHMg
cmV0dXJucyA0MDMgb24gbWFueSBuZXR3b3JrcwogICAgICAgIHJldHVybiAnaHR0
cHM6Ly9pbWFnZS50aHVtLmlvL2dldC93aWR0aC80MDAvY3JvcC8xNjAvbm9hbmlt
YXRlLycgKyBTdHJpbmcodXJsIHx8ICcnKTsKICAgIH0KCiAgICBjb25zdCBFTVBU
WV9NU0cgPSB7CiAgICAgICAgYWxsOiAgICAn5pqC5peg6K6w5b2V77yM5aSN5Yi2
5ZCO6Ieq5Yqo5Ye6546wJywKICAgICAgICB0ZXh0OiAgICfmmoLml6DmlofmnKwn
LAogICAgICAgIGltYWdlOiAgJ+aaguaXoOWbvuWDjycsCiAgICAgICAgZmlsZTog
ICAn5pqC5peg5paH5Lu2JywKICAgICAgICBsaW5rOiAgICfmmoLml6Dpk77mjqXv
vIzlpI3liLblkKsgVVJMIOeahOWGheWuueWQjuWHuueOsCcsCiAgICAgICAgcGlu
bmVkOiAn5pqC5peg5pS26JePJwogICAgfTsKCiAgICBmdW5jdGlvbiBhaGsobWV0
aG9kLCAuLi5hcmdzKSB7CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgY29uc3Qg
aG9zdCA9IGNocm9tZS53ZWJ2aWV3Lmhvc3RPYmplY3RzLnN5bmMuYWhrOwogICAg
ICAgICAgICBpZiAoaG9zdCAmJiB0eXBlb2YgaG9zdC5jYWxsID09PSAnZnVuY3Rp
b24nKSB7IGhvc3QuY2FsbChtZXRob2QsIC4uLmFyZ3MpOyByZXR1cm47IH0KICAg
ICAgICAgICAgaWYgKGhvc3QgJiYgdHlwZW9mIGhvc3RbbWV0aG9kXSA9PT0gJ2Z1
bmN0aW9uJykgeyBob3N0W21ldGhvZF0oaG9zdCwgLi4uYXJncyk7IHJldHVybjsg
fQogICAgICAgICAgICBpZiAoaG9zdCAmJiBob3N0W21ldGhvZF0pIGhvc3RbbWV0
aG9kXSguLi5hcmdzKTsKICAgICAgICB9IGNhdGNoIChlKSB7IGNvbnNvbGUud2Fy
bignYWhrLicgKyBtZXRob2QsIGUpOyB9CiAgICB9CiAgICBmdW5jdGlvbiBhaGtS
ZXQobWV0aG9kLCAuLi5hcmdzKSB7CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAg
Y29uc3QgaG9zdCA9IGNocm9tZS53ZWJ2aWV3Lmhvc3RPYmplY3RzLnN5bmMuYWhr
OwogICAgICAgICAgICBpZiAoIWhvc3QpIHJldHVybiBudWxsOwogICAgICAgICAg
ICBsZXQgcmV0ID0gbnVsbDsKICAgICAgICAgICAgaWYgKHR5cGVvZiBob3N0LmNh
bGwgPT09ICdmdW5jdGlvbicpIHsKICAgICAgICAgICAgICAgIHRyeSB7IHJldCA9
IGhvc3QuY2FsbChtZXRob2QsIC4uLmFyZ3MpOyB9IGNhdGNoIHt9CiAgICAgICAg
ICAgIH0KICAgICAgICAgICAgaWYgKHJldCA9PSBudWxsICYmIHR5cGVvZiBob3N0
W21ldGhvZF0gPT09ICdmdW5jdGlvbicpIHsKICAgICAgICAgICAgICAgIHRyeSB7
IHJldCA9IGhvc3RbbWV0aG9kXSguLi5hcmdzKTsgfSBjYXRjaCB7fQogICAgICAg
ICAgICAgICAgaWYgKHJldCA9PSBudWxsKSB7CiAgICAgICAgICAgICAgICAgICAg
dHJ5IHsgcmV0ID0gaG9zdFttZXRob2RdKGhvc3QsIC4uLmFyZ3MpOyB9IGNhdGNo
IHt9CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgIH0KICAgICAgICAgICAg
aWYgKHJldCA9PSBudWxsICYmIGhvc3RbbWV0aG9kXSAhPSBudWxsICYmIHR5cGVv
ZiBob3N0W21ldGhvZF0gIT09ICdmdW5jdGlvbicpCiAgICAgICAgICAgICAgICBy
ZXQgPSBob3N0W21ldGhvZF07CiAgICAgICAgICAgIGlmIChyZXQgPT0gbnVsbCkg
cmV0dXJuIG51bGw7CiAgICAgICAgICAgIGlmICh0eXBlb2YgcmV0ID09PSAnc3Ry
aW5nJyB8fCB0eXBlb2YgcmV0ID09PSAnbnVtYmVyJyB8fCB0eXBlb2YgcmV0ID09
PSAnYm9vbGVhbicpCiAgICAgICAgICAgICAgICByZXR1cm4gcmV0OwogICAgICAg
ICAgICB0cnkgeyByZXR1cm4gU3RyaW5nKHJldCk7IH0gY2F0Y2ggeyByZXR1cm4g
cmV0OyB9CiAgICAgICAgfSBjYXRjaCAoZSkgeyBjb25zb2xlLndhcm4oJ2Foa1Jl
dC4nICsgbWV0aG9kLCBlKTsgfQogICAgICAgIHJldHVybiBudWxsOwogICAgfQoK
ICAgIC8vIEVhcmx5IEFISyBfX3NldFRodW1iIGNhbiBhcnJpdmUgYmVmb3JlIERP
TSBub2RlcyBleGlzdCDigJQga2VlcCB1bnRpbCBiaW5kCiAgICBjb25zdCB0aHVt
YkNhY2hlID0gbmV3IE1hcCgpOwoKICAgIC8qKiBQcmVmZXIgZGF0YS1VUkwgKEFI
SyksIHRoZW4gdmlydHVhbC1ob3N0IGZpbGUgVVJMICovCiAgICBmdW5jdGlvbiBi
aW5kU3RvcmVUaHVtYihpbWcsIGZpbGUsIGlkLCBmYWxsYmFjaykgewogICAgICAg
IGltZy5kYXRhc2V0LnRodW1iSWQgPSBTdHJpbmcoaWQpOwogICAgICAgIGltZy5h
bHQgPSAnJzsKICAgICAgICBjb25zdCBmYWlsVGltZXIgPSBzZXRUaW1lb3V0KCgp
ID0+IHsKICAgICAgICAgICAgaWYgKCFpbWcuc3JjIHx8IGltZy5uYXR1cmFsV2lk
dGggPCAxKQogICAgICAgICAgICAgICAgaW1nLmFsdCA9ICfml6Dms5XliqDovb0n
OwogICAgICAgIH0sIDEwMDAwKTsKICAgICAgICBpbWcuX2ZhaWxUaW1lciA9IGZh
aWxUaW1lcjsKICAgICAgICBjb25zdCBwcmV2TG9hZCA9IGltZy5vbmxvYWQ7CiAg
ICAgICAgaW1nLm9ubG9hZCA9IGUgPT4gewogICAgICAgICAgICBjbGVhclRpbWVv
dXQoZmFpbFRpbWVyKTsKICAgICAgICAgICAgaW1nLmFsdCA9ICcnOwogICAgICAg
ICAgICBpZiAodHlwZW9mIHByZXZMb2FkID09PSAnZnVuY3Rpb24nKSBwcmV2TG9h
ZC5jYWxsKGltZywgZSk7CiAgICAgICAgfTsKICAgICAgICBpbWcub25lcnJvciA9
ICgpID0+IHsKICAgICAgICAgICAgaWYgKGZpbGUgJiYgIWltZy5kYXRhc2V0LnJl
dHJpZWQpIHsKICAgICAgICAgICAgICAgIGltZy5kYXRhc2V0LnJldHJpZWQgPSAn
MSc7CiAgICAgICAgICAgICAgICBpbWcuc3JjID0gU1RPUkVfQkFTRSArIFN0cmlu
ZyhmaWxlKS5zcGxpdCgnLycpLnBvcCgpOwogICAgICAgICAgICAgICAgcmV0dXJu
OwogICAgICAgICAgICB9CiAgICAgICAgICAgIGltZy5vbmVycm9yID0gbnVsbDsK
ICAgICAgICB9OwogICAgICAgIGNvbnN0IGNhY2hlZCA9IHRodW1iQ2FjaGUuZ2V0
KFN0cmluZyhpZCkpOwogICAgICAgIGNvbnN0IGRhdGFVcmwgPSAoZmFsbGJhY2sg
JiYgU3RyaW5nKGZhbGxiYWNrKS5zdGFydHNXaXRoKCdkYXRhOicpKQogICAgICAg
ICAgICA/IFN0cmluZyhmYWxsYmFjaykKICAgICAgICAgICAgOiAoY2FjaGVkICYm
IFN0cmluZyhjYWNoZWQpLnN0YXJ0c1dpdGgoJ2RhdGE6JykgPyBTdHJpbmcoY2Fj
aGVkKSA6ICcnKTsKICAgICAgICBpZiAoZGF0YVVybCkgewogICAgICAgICAgICBp
bWcuc3JjID0gZGF0YVVybDsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0K
ICAgICAgICBpZiAoZmlsZSkgewogICAgICAgICAgICBjb25zdCBiYXJlID0gU3Ry
aW5nKGZpbGUpLnNwbGl0KCcvJykucG9wKCk7CiAgICAgICAgICAgIGltZy5zcmMg
PSBTVE9SRV9CQVNFICsgYmFyZTsKICAgICAgICB9CiAgICB9CgogICAgd2luZG93
Ll9fc2V0VGh1bWIgPSAoaWQsIHVybCkgPT4gewogICAgICAgIGlmICghdXJsKSBy
ZXR1cm47CiAgICAgICAgY29uc3Qga2V5ID0gU3RyaW5nKGlkKTsKICAgICAgICB0
aHVtYkNhY2hlLnNldChrZXksIHVybCk7CiAgICAgICAgbGV0IGhpdCA9IDA7CiAg
ICAgICAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLml0bVtkYXRhLWlkPSIn
ICsga2V5ICsgJyJdIGltZy5pLXRodW1iJykuZm9yRWFjaChpbWcgPT4gewogICAg
ICAgICAgICBpZiAoaW1nLl9mYWlsVGltZXIpIHRyeSB7IGNsZWFyVGltZW91dChp
bWcuX2ZhaWxUaW1lcik7IH0gY2F0Y2gge30KICAgICAgICAgICAgaW1nLm9uZXJy
b3IgPSBudWxsOwogICAgICAgICAgICBpbWcuYWx0ID0gJyc7CiAgICAgICAgICAg
IGltZy5zcmMgPSB1cmw7CiAgICAgICAgICAgIGhpdCsrOwogICAgICAgIH0pOwog
ICAgICAgIC8vIEFsc28gbWF0Y2ggbnVtZXJpYyBpZCBhdHRyaWJ1dGUgcXVpcmtz
CiAgICAgICAgaWYgKCFoaXQpIHsKICAgICAgICAgICAgZG9jdW1lbnQucXVlcnlT
ZWxlY3RvckFsbCgnaW1nLmktdGh1bWJbZGF0YS10aHVtYi1pZD0iJyArIGtleSAr
ICciXScpLmZvckVhY2goaW1nID0+IHsKICAgICAgICAgICAgICAgIGlmIChpbWcu
X2ZhaWxUaW1lcikgdHJ5IHsgY2xlYXJUaW1lb3V0KGltZy5fZmFpbFRpbWVyKTsg
fSBjYXRjaCB7fQogICAgICAgICAgICAgICAgaW1nLm9uZXJyb3IgPSBudWxsOwog
ICAgICAgICAgICAgICAgaW1nLmFsdCA9ICcnOwogICAgICAgICAgICAgICAgaW1n
LnNyYyA9IHVybDsKICAgICAgICAgICAgfSk7CiAgICAgICAgfQogICAgfTsKCiAg
ICBmdW5jdGlvbiBpc0RyYWdFeGNsdWRlKHQpIHsKICAgICAgICByZXR1cm4gISF0
LmNsb3Nlc3QoJyNzZWFyY2gtd3JhcCwgI2J0bi1zZWFyY2gsICNidG4tbG9jYXRl
LCAjYnRuLXRvZGF5LCAjYnRuLXBpbiwgI2J0bi1jbHIsICNtdWx0aS1jbnQsIC50
YWIsIC5pdG0sICN0YWItYWN0aW9ucywgI2N0eCwgI2Nsci1kbGcsICNwYXRoLXRp
cCwgYnV0dG9uLCBpbnB1dCwgYScpOwogICAgfQogICAgZG9jdW1lbnQuZ2V0RWxl
bWVudEJ5SWQoJ2FwcCcpLmFkZEV2ZW50TGlzdGVuZXIoJ21vdXNlZG93bicsIGUg
PT4gewogICAgICAgIGlmIChlLmJ1dHRvbiAhPT0gMCkgcmV0dXJuOwogICAgICAg
IGlmIChpc0RyYWdFeGNsdWRlKGUudGFyZ2V0KSkgcmV0dXJuOwogICAgICAgIGUu
cHJldmVudERlZmF1bHQoKTsKICAgICAgICBhaGsoJ3N0YXJ0RHJhZycpOwogICAg
fSwgdHJ1ZSk7CgogICAgY29uc3QgaXNVcmwgID0gcyA9PiAvXmh0dHBzPzpcL1wv
L2kudGVzdCgocyB8fCAnJykudHJpbSgpKTsKCiAgICBmdW5jdGlvbiBhZ28oZGF0
ZVN0cikgewogICAgICAgIHRyeSB7CiAgICAgICAgICAgIGNvbnN0IGQgPSBuZXcg
RGF0ZShTdHJpbmcoZGF0ZVN0cikucmVwbGFjZSgnICcsICdUJykpOwogICAgICAg
ICAgICBjb25zdCBzID0gKERhdGUubm93KCkgLSBkKSAvIDEwMDAgfCAwOwogICAg
ICAgICAgICBpZiAocyA8IDYwKSByZXR1cm4gJ+WImuWImic7CiAgICAgICAgICAg
IGlmIChzIDwgMzYwMCkgcmV0dXJuIChzIC8gNjAgfCAwKSArICcg5YiG6ZKf5YmN
JzsKICAgICAgICAgICAgaWYgKHMgPCA4NjQwMCkgcmV0dXJuIChzIC8gMzYwMCB8
IDApICsgJyDlsI/ml7bliY0nOwogICAgICAgICAgICByZXR1cm4gKHMgLyA4NjQw
MCB8IDApICsgJyDlpKnliY0nOwogICAgICAgIH0gY2F0Y2ggeyByZXR1cm4gZGF0
ZVN0cjsgfQogICAgfQoKICAgIGZ1bmN0aW9uIG5vcm1UeXBlKHQpIHsKICAgICAg
ICB0ID0gU3RyaW5nKHQgfHwgJycpLnRvTG93ZXJDYXNlKCk7CiAgICAgICAgaWYg
KHQgPT09ICdpbWFnZScgfHwgdCA9PT0gJ2ltZycgfHwgdCA9PT0gJ2JpdG1hcCcp
IHJldHVybiAnaW1hZ2UnOwogICAgICAgIGlmICh0ID09PSAnZmlsZScgIHx8IHQg
PT09ICdmaWxlcycpIHJldHVybiAnZmlsZSc7CiAgICAgICAgaWYgKHQgPT09ICds
aW5rJyAgfHwgdCA9PT0gJ3VybCcpIHJldHVybiAnbGluayc7CiAgICAgICAgcmV0
dXJuICd0ZXh0JzsKICAgIH0KICAgIGZ1bmN0aW9uIGlzUGlubmVkKGMpIHsKICAg
ICAgICByZXR1cm4gYy5waW5uZWQgPT09IHRydWUgfHwgYy5waW5uZWQgPT09IDEg
fHwgYy5waW5uZWQgPT09ICd0cnVlJyB8fCBjLnBpbm5lZCA9PT0gJzEnOwogICAg
fQogICAgZnVuY3Rpb24gaXNQYXN0ZWQoYykgewogICAgICAgIHJldHVybiBjLnBh
c3RlZCA9PT0gdHJ1ZSB8fCBjLnBhc3RlZCA9PT0gMSB8fCBjLnBhc3RlZCA9PT0g
J3RydWUnIHx8IGMucGFzdGVkID09PSAnMSc7CiAgICB9CgogICAgZnVuY3Rpb24g
aXNNYXJrZG93bih0ZXh0KSB7CiAgICAgICAgaWYgKCF0ZXh0IHx8IHRleHQubGVu
Z3RoIDwgNCkgcmV0dXJuIGZhbHNlOwogICAgICAgIHJldHVybiAvKD86Xnxcbikj
ezEsNn0gfF5bLSorXSB8XCpcKlteKlxuXStcKlwqfF9fW15fXG5dK19ffCg/Ol58
XG4pPiB8XmBgYHxgW15gXStgfFxbLitcXVwoLitcKXxcfC4rXHwuK1x8Ly50ZXN0
KHRleHQpOwogICAgfQogICAgZnVuY3Rpb24gZXNjQXR0cihzKSB7CiAgICAgICAg
cmV0dXJuIFN0cmluZyhzIHx8ICcnKQogICAgICAgICAgICAucmVwbGFjZSgvJi9n
LCAnJmFtcDsnKQogICAgICAgICAgICAucmVwbGFjZSgvIi9nLCAnJnF1b3Q7JykK
ICAgICAgICAgICAgLnJlcGxhY2UoLzwvZywgJyZsdDsnKQogICAgICAgICAgICAu
cmVwbGFjZSgvPi9nLCAnJmd0OycpOwogICAgfQoKICAgIGZ1bmN0aW9uIHRvZGF5
UHJlZml4KCkgewogICAgICAgIGNvbnN0IGQgPSBuZXcgRGF0ZSgpOwogICAgICAg
IGNvbnN0IHAgPSBuID0+IFN0cmluZyhuKS5wYWRTdGFydCgyLCAnMCcpOwogICAg
ICAgIHJldHVybiBkLmdldEZ1bGxZZWFyKCkgKyAnLScgKyBwKGQuZ2V0TW9udGgo
KSArIDEpICsgJy0nICsgcChkLmdldERhdGUoKSk7CiAgICB9CiAgICBmdW5jdGlv
biBpc1RvZGF5Q2xpcChjKSB7CiAgICAgICAgcmV0dXJuIFN0cmluZyhjLnRpbWUg
fHwgJycpLnN0YXJ0c1dpdGgodG9kYXlQcmVmaXgoKSk7CiAgICB9CgogICAgZnVu
Y3Rpb24gZmlsdGVyKGNsaXBzLCB0YWIsIHEpIHsKICAgICAgICAvLyBBSEsgYWxy
ZWFkeSBmaWx0ZXJzIGJ5IHRhYiAvIHF1ZXJ5IC8gdG9kYXkg4oCUIGtlZXAgbGlz
dCBhcy1pcyBmb3IgcmVuZGVyCiAgICAgICAgcmV0dXJuIGNsaXBzLm1hcChjID0+
ICh7IC4uLmMsIHR5cGU6IG5vcm1UeXBlKGMudHlwZSksIHBpbm5lZDogaXNQaW5u
ZWQoYyksIHBhc3RlZDogaXNQYXN0ZWQoYykgfSkpOwogICAgfQoKICAgIGZ1bmN0
aW9uIG1hcmtQYXN0ZWRMb2NhbChpZHMpIHsKICAgICAgICBjb25zdCBsaXN0ID0g
QXJyYXkuaXNBcnJheShpZHMpID8gaWRzIDogW2lkc107CiAgICAgICAgaWYgKGxp
c3QubGVuZ3RoKQogICAgICAgICAgICByZW1lbWJlckxhc3RQYXN0ZShsaXN0W2xp
c3QubGVuZ3RoIC0gMV0pOwogICAgICAgIGNvbnN0IGJhZGdlSHRtbCA9IGA8c3Zn
IHZpZXdCb3g9IjAgMCAxNiAxNiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50
Q29sb3IiIHN0cm9rZS13aWR0aD0iMi40IiBzdHJva2UtbGluZWNhcD0icm91bmQi
IHN0cm9rZS1saW5lam9pbj0icm91bmQiPjxwb2x5bGluZSBwb2ludHM9IjMuNSA4
LjUgNi41IDExLjUgMTIuNSA0LjUiLz48L3N2Zz5gOwogICAgICAgIGxpc3QuZm9y
RWFjaChpZCA9PiB7CiAgICAgICAgICAgIGNvbnN0IGMgPSBhbGxDbGlwcy5maW5k
KHggPT4gK3guaWQgPT09ICtpZCk7CiAgICAgICAgICAgIGlmIChjKSBjLnBhc3Rl
ZCA9IHRydWU7CiAgICAgICAgICAgIGNvbnN0IGljbyA9IGxpc3RFbC5xdWVyeVNl
bGVjdG9yKCcuaXRtW2RhdGEtaWQ9IicgKyBpZCArICciXSAuaS1pY28nKTsKICAg
ICAgICAgICAgaWYgKGljbyAmJiAhaWNvLnF1ZXJ5U2VsZWN0b3IoJy5pLXVzZWQn
KSkgewogICAgICAgICAgICAgICAgY29uc3QgYmFkZ2UgPSBkb2N1bWVudC5jcmVh
dGVFbGVtZW50KCdzcGFuJyk7CiAgICAgICAgICAgICAgICBiYWRnZS5jbGFzc05h
bWUgPSAnaS11c2VkJzsKICAgICAgICAgICAgICAgIGJhZGdlLnRpdGxlID0gJ+W3
sueymOi0tCc7CiAgICAgICAgICAgICAgICBiYWRnZS5pbm5lckhUTUwgPSBiYWRn
ZUh0bWw7CiAgICAgICAgICAgICAgICBpY28uYXBwZW5kQ2hpbGQoYmFkZ2UpOwog
ICAgICAgICAgICB9CiAgICAgICAgfSk7CiAgICB9CgogICAgY29uc3QgbGlzdEVs
ICA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdsaXN0Jyk7CiAgICBjb25zdCBl
bXB0eUVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2VtcHR5Jyk7CiAgICBj
b25zdCBidG5Ub3AgID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi10b3An
KTsKCiAgICBmdW5jdGlvbiBzdG9wTGlua01lZGlhKCkgewogICAgICAgIGxpbmtM
b2FkQWN0aXZlID0gZmFsc2U7CiAgICAgICAgdHJ5IHsgYWhrKCdzdG9wTGlua01l
dGEnKTsgfSBjYXRjaCB7fQogICAgICAgIGxpbmtPYnNlcnZlcnMuZm9yRWFjaChp
byA9PiB7IHRyeSB7IGlvLmRpc2Nvbm5lY3QoKTsgfSBjYXRjaCB7fSB9KTsKICAg
ICAgICBsaW5rT2JzZXJ2ZXJzID0gW107CiAgICAgICAgaWYgKCFsaXN0RWwpIHJl
dHVybjsKICAgICAgICBsaXN0RWwucXVlcnlTZWxlY3RvckFsbCgnLmktbGluay1z
aG90IGltZywgLmktaWNvLmxpbmsgaW1nJykuZm9yRWFjaChpbWcgPT4gewogICAg
ICAgICAgICB0cnkgewogICAgICAgICAgICAgICAgaW1nLm9ubG9hZCA9IG51bGw7
CiAgICAgICAgICAgICAgICBpbWcub25lcnJvciA9IG51bGw7CiAgICAgICAgICAg
ICAgICBpbWcucmVtb3ZlQXR0cmlidXRlKCdzcmMnKTsKICAgICAgICAgICAgICAg
IGltZy5zcmMgPSAnJzsKICAgICAgICAgICAgfSBjYXRjaCB7fQogICAgICAgIH0p
OwogICAgfQogICAgZnVuY3Rpb24gdXBkYXRlVG9wQnRuKCkgewogICAgICAgIGlm
ICghYnRuVG9wIHx8ICFsaXN0RWwpIHJldHVybjsKICAgICAgICBidG5Ub3AuY2xh
c3NMaXN0LnRvZ2dsZSgnb24nLCBsaXN0RWwuc2Nyb2xsVG9wID4gNDgpOwogICAg
fQogICAgZnVuY3Rpb24gb25MaXN0U2Nyb2xsKCkgewogICAgICAgIGhpZGVQYXRo
VGlwKCk7CiAgICAgICAgdXBkYXRlVG9wQnRuKCk7CiAgICAgICAgaWYgKGxvYWRp
bmdNb3JlKSByZXR1cm47CiAgICAgICAgaWYgKGxpc3RFbC5zY3JvbGxUb3AgKyBs
aXN0RWwuY2xpZW50SGVpZ2h0ID49IGxpc3RFbC5zY3JvbGxIZWlnaHQgLSAxMDAp
CiAgICAgICAgICAgIHJlcXVlc3RNb3JlKCk7CiAgICB9CiAgICBsaXN0RWwuYWRk
RXZlbnRMaXN0ZW5lcignc2Nyb2xsJywgb25MaXN0U2Nyb2xsLCB7IHBhc3NpdmU6
IHRydWUgfSk7CiAgICBidG5Ub3AuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBl
ID0+IHsKICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgIGxpc3RF
bC5zY3JvbGxUbyh7IHRvcDogMCwgYmVoYXZpb3I6ICdzbW9vdGgnIH0pOwogICAg
fSk7CgogICAgZnVuY3Rpb24gdmlzaWJsZUxpc3QoKSB7IHJldHVybiBmaWx0ZXIo
YWxsQ2xpcHMsIGN1clRhYiwgcXVlcnkpOyB9CgogICAgZnVuY3Rpb24gc2hvd25M
aXN0KCkgeyByZXR1cm4gdmlzaWJsZUxpc3QoKTsgfQoKICAgIGZ1bmN0aW9uIHNl
dFRhYih0YWIpIHsKICAgICAgICBpZiAodGFiID09PSBjdXJUYWIpIHJldHVybjsK
ICAgICAgICBjb25zdCBwcmV2ID0gY3VyVGFiOwogICAgICAgIGN1clRhYiA9IHRh
YjsKICAgICAgICBsb2FkaW5nTW9yZSA9IGZhbHNlOwogICAgICAgIGRvY3VtZW50
LnF1ZXJ5U2VsZWN0b3JBbGwoJy50YWInKS5mb3JFYWNoKGVsID0+IGVsLmNsYXNz
TGlzdC50b2dnbGUoJ29uJywgZWwuZGF0YXNldC50YWIgPT09IHRhYikpOwoKICAg
ICAgICBpZiAocHJldiA9PT0gJ2xpbmsnICYmIHRhYiAhPT0gJ2xpbmsnKQogICAg
ICAgICAgICBzdG9wTGlua01lZGlhKCk7CiAgICAgICAgaWYgKHRhYiA9PT0gJ2xp
bmsnKQogICAgICAgICAgICBsaW5rTG9hZEFjdGl2ZSA9IHRydWU7CgogICAgICAg
IC8vIFNlYXJjaCBvcGVuOiDmlLbol48g4oaSIOaQnOWFqOmDqO+8m+WFtuWug+mh
tSDihpIg6buY6K6k5b2T5aSpCiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgY29u
c3Qgd3JhcCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gtd3JhcCcp
OwogICAgICAgICAgICBjb25zdCBidG5Ub2RheSA9IGRvY3VtZW50LmdldEVsZW1l
bnRCeUlkKCdidG4tdG9kYXknKTsKICAgICAgICAgICAgaWYgKHdyYXAgJiYgd3Jh
cC5jbGFzc0xpc3QuY29udGFpbnMoJ29wZW4nKSkgewogICAgICAgICAgICAgICAg
Y29uc3Qgd2FudFRvZGF5ID0gKHRhYiAhPT0gJ3Bpbm5lZCcpOwogICAgICAgICAg
ICAgICAgaWYgKHRvZGF5T25seSAhPT0gd2FudFRvZGF5KSB7CiAgICAgICAgICAg
ICAgICAgICAgdG9kYXlPbmx5ID0gd2FudFRvZGF5OwogICAgICAgICAgICAgICAg
ICAgIGlmIChidG5Ub2RheSkgYnRuVG9kYXkuY2xhc3NMaXN0LnRvZ2dsZSgnb24n
LCB0b2RheU9ubHkpOwogICAgICAgICAgICAgICAgfQogICAgICAgICAgICB9CiAg
ICAgICAgfSBjYXRjaCB7fQoKICAgICAgICBsaXN0RWwuc2Nyb2xsVG9wID0gMDsK
ICAgICAgICByZXF1ZXN0VmlldygpOwogICAgfQoKICAgIGZ1bmN0aW9uIGZpbmRT
b3VyY2VDbGlwKHVybCkgewogICAgICAgIGNvbnN0IHUgPSBTdHJpbmcodXJsIHx8
ICcnKS50cmltKCk7CiAgICAgICAgaWYgKCF1KSByZXR1cm4gbnVsbDsKICAgICAg
ICAvLyBOZXdlc3QgdGV4dCBjbGlwIHRoYXQgY29udGFpbnMgdGhpcyBVUkwKICAg
ICAgICBmb3IgKGNvbnN0IGMgb2YgYWxsQ2xpcHMpIHsKICAgICAgICAgICAgaWYg
KG5vcm1UeXBlKGMudHlwZSkgIT09ICd0ZXh0JykgY29udGludWU7CiAgICAgICAg
ICAgIGNvbnN0IGRhdGEgPSBTdHJpbmcoYy5kYXRhIHx8ICcnKTsKICAgICAgICAg
ICAgaWYgKGRhdGEuaW5jbHVkZXModSkpIHJldHVybiBjOwogICAgICAgIH0KICAg
ICAgICByZXR1cm4gbnVsbDsKICAgIH0KCiAgICBmdW5jdGlvbiBqdW1wVG9Tb3Vy
Y2UodXJsKSB7CiAgICAgICAgY29uc3Qgc3JjID0gZmluZFNvdXJjZUNsaXAodXJs
KTsKICAgICAgICBpZiAoIXNyYykgcmV0dXJuIGZhbHNlOwogICAgICAgIHN0b3BM
aW5rTWVkaWEoKTsKICAgICAgICBjdXJUYWIgPSAnYWxsJzsKICAgICAgICBsaW5r
TG9hZEFjdGl2ZSA9IGZhbHNlOwogICAgICAgIGxvYWRpbmdNb3JlID0gZmFsc2U7
CiAgICAgICAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLnRhYicpLmZvckVh
Y2goZWwgPT4KICAgICAgICAgICAgZWwuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCBl
bC5kYXRhc2V0LnRhYiA9PT0gJ2FsbCcpKTsKICAgICAgICBzZWxlY3RlZElkID0g
c3JjLmlkOwogICAgICAgIGNsZWFyTXVsdGkoKTsKICAgICAgICByZXF1ZXN0Vmll
dygpOwogICAgICAgIC8vIEFmdGVyIHZpZXcgcmVsb2FkLCB0cnkgdG8gc2Nyb2xs
IHRvIHNvdXJjZSB3aGVuIGl0ZW1zIGFycml2ZQogICAgICAgIHdpbmRvdy5fX3Bl
bmRpbmdKdW1wSWQgPSBzZWxlY3RlZElkOwogICAgICAgIHJldHVybiB0cnVlOwog
ICAgfQoKICAgIGZ1bmN0aW9uIHVwZGF0ZU1vcmVGb290ZXIodG90YWwpIHsKICAg
ICAgICBsZXQgbW9yZUVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2xpc3Qt
bW9yZScpOwogICAgICAgIGNvbnN0IGxvYWRlZCA9IGFsbENsaXBzLmxlbmd0aDsK
ICAgICAgICBpZiAobG9hZGVkID49IHRvdGFsKSB7CiAgICAgICAgICAgIGlmICht
b3JlRWwpIG1vcmVFbC5yZW1vdmUoKTsKICAgICAgICAgICAgcmV0dXJuOwogICAg
ICAgIH0KICAgICAgICBpZiAoIW1vcmVFbCkgewogICAgICAgICAgICBtb3JlRWwg
PSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgbW9y
ZUVsLmlkID0gJ2xpc3QtbW9yZSc7CiAgICAgICAgICAgIG1vcmVFbC5jbGFzc05h
bWUgPSAnbGlzdC1tb3JlJzsKICAgICAgICAgICAgbGlzdEVsLmFwcGVuZENoaWxk
KG1vcmVFbCk7CiAgICAgICAgfQogICAgICAgIG1vcmVFbC50ZXh0Q29udGVudCA9
ICfnu6fnu63kuIvmu5Hku47no4Hnm5jliqDovb3vvIgnICsgbG9hZGVkICsgJy8n
ICsgdG90YWwgKyAn77yJJzsKICAgIH0KCiAgICBmdW5jdGlvbiBzZWxlY3RCeUlu
ZGV4KGlkeCkgewogICAgICAgIGNvbnN0IHZpcyA9IHZpc2libGVMaXN0KCk7CiAg
ICAgICAgaWYgKCF2aXMubGVuZ3RoKSByZXR1cm47CiAgICAgICAgaWR4ID0gTWF0
aC5tYXgoMCwgTWF0aC5taW4odmlzLmxlbmd0aCAtIDEsIGlkeCkpOwogICAgICAg
IGlmIChpZHggPj0gdmlzLmxlbmd0aCAtIDEgJiYgYWxsQ2xpcHMubGVuZ3RoIDwg
ZGlza1RvdGFsKQogICAgICAgICAgICByZXF1ZXN0TW9yZSgpOwogICAgICAgIHNl
bGVjdGVkSWQgPSB2aXNbTWF0aC5taW4oaWR4LCB2aXMubGVuZ3RoIC0gMSldLmlk
OwogICAgICAgIGlmICgrc2VsZWN0ZWRJZCAhPT0gK2xhc3RQYXN0ZUlkKQogICAg
ICAgICAgICBsb2NhdGVBY3RpdmUgPSBmYWxzZTsKICAgICAgICB1cGRhdGVMb2Nh
dGVCdG4oKTsKICAgICAgICBzeW5jSXRlbUhpZ2hsaWdodCgpOwogICAgICAgIGNv
bnN0IGVsID0gbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5pdG1bZGF0YS1pZD0iJyAr
IHNlbGVjdGVkSWQgKyAnIl0nKTsKICAgICAgICBpZiAoZWwpIGVsLnNjcm9sbElu
dG9WaWV3KHsgYmxvY2s6ICduZWFyZXN0JyB9KTsKICAgIH0KCiAgICBmdW5jdGlv
biBzZWxlY3RlZEluZGV4KCkgewogICAgICAgIHJldHVybiB2aXNpYmxlTGlzdCgp
LmZpbmRJbmRleChjID0+IGMuaWQgPT0gc2VsZWN0ZWRJZCk7CiAgICB9CgogICAg
ZnVuY3Rpb24gc3luY0l0ZW1IaWdobGlnaHQoKSB7CiAgICAgICAgZG9jdW1lbnQu
cXVlcnlTZWxlY3RvckFsbCgnLml0bScpLmZvckVhY2gobiA9PiB7CiAgICAgICAg
ICAgIGlmIChuLmNsYXNzTGlzdC5jb250YWlucygnaXQtZ3JvdXAnKSkgewogICAg
ICAgICAgICAgICAgY29uc3Qgcm93cyA9IFsuLi5uLnF1ZXJ5U2VsZWN0b3JBbGwo
Jy5tZy1yb3cnKV07CiAgICAgICAgICAgICAgICBjb25zdCBpZHMgPSByb3dzLm1h
cChyID0+ICtyLmRhdGFzZXQuaWQpOwogICAgICAgICAgICAgICAgbi5jbGFzc0xp
c3QudG9nZ2xlKCdzZWwnLCBpZHMuaW5jbHVkZXMoK3NlbGVjdGVkSWQpKTsKICAg
ICAgICAgICAgICAgIG4uY2xhc3NMaXN0LnRvZ2dsZSgnbXVsdGknLCBpZHMuc29t
ZShpZCA9PiBtdWx0aUlkcy5pbmNsdWRlcyhpZCkpKTsKICAgICAgICAgICAgICAg
IHJvd3MuZm9yRWFjaChyID0+IHsKICAgICAgICAgICAgICAgICAgICBjb25zdCBp
ZCA9ICtyLmRhdGFzZXQuaWQ7CiAgICAgICAgICAgICAgICAgICAgci5jbGFzc0xp
c3QudG9nZ2xlKCdzZWwnLCBpZCA9PSBzZWxlY3RlZElkKTsKICAgICAgICAgICAg
ICAgICAgICByLmNsYXNzTGlzdC50b2dnbGUoJ211bHRpJywgbXVsdGlJZHMuaW5j
bHVkZXMoaWQpKTsKICAgICAgICAgICAgICAgIH0pOwogICAgICAgICAgICAgICAg
cmV0dXJuOwogICAgICAgICAgICB9CiAgICAgICAgICAgIGNvbnN0IGlkID0gK24u
ZGF0YXNldC5pZDsKICAgICAgICAgICAgbi5jbGFzc0xpc3QudG9nZ2xlKCdzZWwn
LCBpZCA9PSBzZWxlY3RlZElkKTsKICAgICAgICAgICAgbi5jbGFzc0xpc3QudG9n
Z2xlKCdtdWx0aScsIG11bHRpSWRzLmluY2x1ZGVzKGlkKSk7CiAgICAgICAgfSk7
CiAgICB9CiAgICBmdW5jdGlvbiB1cGRhdGVNdWx0aUJhZGdlKCkgewogICAgICAg
IGNvbnN0IGVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ211bHRpLWNudCcp
OwogICAgICAgIGlmIChtdWx0aUlkcy5sZW5ndGggPiAwKSB7CiAgICAgICAgICAg
IGVsLnRleHRDb250ZW50ID0gJ+W3sumAiSAnICsgbXVsdGlJZHMubGVuZ3RoOwog
ICAgICAgICAgICBlbC5jbGFzc0xpc3QuYWRkKCdvbicpOwogICAgICAgIH0gZWxz
ZSB7CiAgICAgICAgICAgIGVsLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAg
ICAgfQogICAgICAgIHN5bmNJdGVtSGlnaGxpZ2h0KCk7CiAgICB9CgogICAgZnVu
Y3Rpb24gY2xlYXJNdWx0aSgpIHsKICAgICAgICBtdWx0aUlkcyA9IFtdOwogICAg
ICAgIHVwZGF0ZU11bHRpQmFkZ2UoKTsKICAgIH0KCiAgICBmdW5jdGlvbiB0b2dn
bGVNdWx0aShpZCkgewogICAgICAgIGlkID0gK2lkOwogICAgICAgIGNvbnN0IGkg
PSBtdWx0aUlkcy5pbmRleE9mKGlkKTsKICAgICAgICBpZiAoaSA+PSAwKSBtdWx0
aUlkcy5zcGxpY2UoaSwgMSk7CiAgICAgICAgZWxzZSBtdWx0aUlkcy5wdXNoKGlk
KTsKICAgICAgICBzZWxlY3RlZElkID0gaWQ7CiAgICAgICAgdXBkYXRlTXVsdGlC
YWRnZSgpOwogICAgfQoKICAgIGZ1bmN0aW9uIHJlbmRlcigpIHsKICAgICAgICBo
aWRlUGF0aFRpcCgpOwogICAgICAgIGxpbmtPYnNlcnZlcnMuZm9yRWFjaChpbyA9
PiB7IHRyeSB7IGlvLmRpc2Nvbm5lY3QoKTsgfSBjYXRjaCB7fSB9KTsKICAgICAg
ICBsaW5rT2JzZXJ2ZXJzID0gW107CgogICAgICAgIGNvbnN0IHZpc2libGUgPSB2
aXNpYmxlTGlzdCgpOwogICAgICAgIGNvbnN0IHBpbm5lZE4gPSBhbGxDbGlwcy5m
aWx0ZXIoYyA9PiBpc1Bpbm5lZChjKSkubGVuZ3RoOwogICAgICAgIGNvbnN0IHBp
bkNudCAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncGluLWNudCcpOwogICAg
ICAgIHBpbkNudC50ZXh0Q29udGVudCAgID0gcGlubmVkTjsKICAgICAgICBwaW5D
bnQuc3R5bGUuZGlzcGxheSA9IHBpbm5lZE4gPyAnJyA6ICdub25lJzsKICAgICAg
ICBjb25zdCBsb2FkZWQgPSB2aXNpYmxlLmxlbmd0aDsKICAgICAgICBkb2N1bWVu
dC5nZXRFbGVtZW50QnlJZCgnYmFyLXR4dCcpLnRleHRDb250ZW50ID0KICAgICAg
ICAgICAgZGlza1RvdGFsID4gbG9hZGVkID8gKGxvYWRlZCArICcgLyAnICsgZGlz
a1RvdGFsICsgJyDmnaEnKSA6IChkaXNrVG90YWwgKyAnIOadoScpOwogICAgICAg
IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdlbXB0eS10eHQnKS50ZXh0Q29udGVu
dCA9IEVNUFRZX01TR1tjdXJUYWJdIHx8IEVNUFRZX01TRy5hbGw7CgogICAgICAg
IGNvbnN0IGlkU2V0ID0gbmV3IFNldChhbGxDbGlwcy5tYXAoYyA9PiArYy5pZCkp
OwogICAgICAgIG11bHRpSWRzID0gbXVsdGlJZHMuZmlsdGVyKGlkID0+IGlkU2V0
LmhhcyhpZCkpOwogICAgICAgIHVwZGF0ZU11bHRpQmFkZ2UoKTsKCiAgICAgICAg
Y29uc3Qgc2hvd24gPSB2aXNpYmxlOwoKICAgICAgICBsaXN0RWwucXVlcnlTZWxl
Y3RvckFsbCgnLml0bSwgI2xpc3QtbW9yZScpLmZvckVhY2goZSA9PiBlLnJlbW92
ZSgpKTsKICAgICAgICBpZiAoIXZpc2libGUubGVuZ3RoKSB7CiAgICAgICAgICAg
IGlmIChzZWxlY3RGaXJzdE9uU2hvdykgewogICAgICAgICAgICAgICAgc2VsZWN0
Rmlyc3RPblNob3cgPSBmYWxzZTsKICAgICAgICAgICAgICAgIHNlbGVjdGVkSWQg
PSAwOwogICAgICAgICAgICAgICAgY2xlYXJNdWx0aSgpOwogICAgICAgICAgICAg
ICAgbGlzdEVsLnNjcm9sbFRvcCA9IDA7CiAgICAgICAgICAgIH0KICAgICAgICAg
ICAgZW1wdHlFbC5jbGFzc0xpc3QuYWRkKCdvbicpOwogICAgICAgICAgICB1cGRh
dGVUb3BCdG4oKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAg
ICBlbXB0eUVsLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgY29uc3Qg
ZnJhZyA9IGRvY3VtZW50LmNyZWF0ZURvY3VtZW50RnJhZ21lbnQoKTsKICAgICAg
ICBjb25zdCBibG9ja3MgPSBidWlsZFBpbm5lZEJsb2NrcyhzaG93bik7CiAgICAg
ICAgbGV0IG51bSA9IDA7CiAgICAgICAgYmxvY2tzLmZvckVhY2goYiA9PiB7CiAg
ICAgICAgICAgIG51bSArPSAxOwogICAgICAgICAgICBpZiAoYi5raW5kID09PSAn
Z3JvdXAnICYmIGIuaXRlbXMubGVuZ3RoID4gMSkKICAgICAgICAgICAgICAgIGZy
YWcuYXBwZW5kQ2hpbGQobWFrZUdyb3VwSXRlbShiLml0ZW1zLCBudW0pKTsKICAg
ICAgICAgICAgZWxzZQogICAgICAgICAgICAgICAgZnJhZy5hcHBlbmRDaGlsZCht
YWtlSXRlbShiLml0ZW1zWzBdLCBudW0pKTsKICAgICAgICB9KTsKICAgICAgICBs
aXN0RWwuYXBwZW5kQ2hpbGQoZnJhZyk7CiAgICAgICAgdXBkYXRlTW9yZUZvb3Rl
cihkaXNrVG90YWwpOwogICAgICAgIGlmIChzZWxlY3RGaXJzdE9uU2hvdykgewog
ICAgICAgICAgICBzZWxlY3RGaXJzdE9uU2hvdyA9IGZhbHNlOwogICAgICAgICAg
ICBzZWxlY3RlZElkID0gdmlzaWJsZVswXS5pZDsKICAgICAgICAgICAgY2xlYXJN
dWx0aSgpOwogICAgICAgICAgICBsaXN0RWwuc2Nyb2xsVG9wID0gMDsKICAgICAg
ICB9IGVsc2UgaWYgKCF2aXNpYmxlLnNvbWUoYyA9PiBjLmlkID09IHNlbGVjdGVk
SWQpKSB7CiAgICAgICAgICAgIHNlbGVjdGVkSWQgPSB2aXNpYmxlWzBdLmlkOwog
ICAgICAgIH0KICAgICAgICBzeW5jSXRlbUhpZ2hsaWdodCgpOwogICAgICAgIHVw
ZGF0ZVRvcEJ0bigpOwogICAgICAgIGlmICh3aW5kb3cuX19wZW5kaW5nSnVtcElk
KSB7CiAgICAgICAgICAgIGNvbnN0IGppZCA9ICt3aW5kb3cuX19wZW5kaW5nSnVt
cElkOwogICAgICAgICAgICBjb25zdCBlbCA9IGxpc3RFbC5xdWVyeVNlbGVjdG9y
KCcubWctcm93W2RhdGEtaWQ9IicgKyBqaWQgKyAnIl0nKSB8fCBsaXN0RWwucXVl
cnlTZWxlY3RvcignLml0bVtkYXRhLWlkPSInICsgamlkICsgJyJdJyk7CiAgICAg
ICAgICAgIGlmIChlbCkgewogICAgICAgICAgICAgICAgd2luZG93Ll9fcGVuZGlu
Z0p1bXBJZCA9IDA7CiAgICAgICAgICAgICAgICB3aW5kb3cuX19qdW1wTG9hZFRy
aWVzID0gMDsKICAgICAgICAgICAgICAgIHNlbGVjdGVkSWQgPSBqaWQ7CiAgICAg
ICAgICAgICAgICByZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4gewogICAgICAg
ICAgICAgICAgICAgIGNvbnN0IG5vZGUgPSBsaXN0RWwucXVlcnlTZWxlY3Rvcign
Lm1nLXJvd1tkYXRhLWlkPSInICsgamlkICsgJyJdJykgfHwgbGlzdEVsLnF1ZXJ5
U2VsZWN0b3IoJy5pdG1bZGF0YS1pZD0iJyArIGppZCArICciXScpOwogICAgICAg
ICAgICAgICAgICAgIGlmICghbm9kZSkgcmV0dXJuOwogICAgICAgICAgICAgICAg
ICAgIG5vZGUuc2Nyb2xsSW50b1ZpZXcoeyBibG9jazogJ2NlbnRlcicgfSk7CiAg
ICAgICAgICAgICAgICAgICAgbm9kZS5jbGFzc0xpc3QuYWRkKCdqdW1wLWZsYXNo
Jyk7CiAgICAgICAgICAgICAgICAgICAgc2V0VGltZW91dCgoKSA9PiBub2RlLmNs
YXNzTGlzdC5yZW1vdmUoJ2p1bXAtZmxhc2gnKSwgOTAwKTsKICAgICAgICAgICAg
ICAgICAgICBzeW5jSXRlbUhpZ2hsaWdodCgpOwogICAgICAgICAgICAgICAgfSk7
CiAgICAgICAgICAgIH0gZWxzZSBpZiAoYWxsQ2xpcHMubGVuZ3RoIDwgZGlza1Rv
dGFsICYmICh3aW5kb3cuX19qdW1wTG9hZFRyaWVzIHx8IDApIDwgNDApIHsKICAg
ICAgICAgICAgICAgIHdpbmRvdy5fX2p1bXBMb2FkVHJpZXMgPSAod2luZG93Ll9f
anVtcExvYWRUcmllcyB8fCAwKSArIDE7CiAgICAgICAgICAgICAgICByZXF1ZXN0
TW9yZSgpOwogICAgICAgICAgICB9IGVsc2UgaWYgKGN1clRhYiAhPT0gJ2FsbCcg
JiYgIXdpbmRvdy5fX2p1bXBGZWxsQmFjaykgewogICAgICAgICAgICAgICAgLy8g
SXRlbSBnb25lIGZyb20gdGhpcyB0YWIgKGUuZy4gdW5waW5uZWQpIOKAlCBmYWxs
IGJhY2sgdG8g5YWo6YOoIG9uY2UKICAgICAgICAgICAgICAgIHdpbmRvdy5fX2p1
bXBGZWxsQmFjayA9IHRydWU7CiAgICAgICAgICAgICAgICB3aW5kb3cuX19qdW1w
TG9hZFRyaWVzID0gMDsKICAgICAgICAgICAgICAgIGN1clRhYiA9ICdhbGwnOwog
ICAgICAgICAgICAgICAgbGlua0xvYWRBY3RpdmUgPSBmYWxzZTsKICAgICAgICAg
ICAgICAgIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy50YWInKS5mb3JFYWNo
KGVsID0+CiAgICAgICAgICAgICAgICAgICAgZWwuY2xhc3NMaXN0LnRvZ2dsZSgn
b24nLCBlbC5kYXRhc2V0LnRhYiA9PT0gJ2FsbCcpKTsKICAgICAgICAgICAgICAg
IHJlcXVlc3RWaWV3KCk7CiAgICAgICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAg
ICAgICB3aW5kb3cuX19wZW5kaW5nSnVtcElkID0gMDsKICAgICAgICAgICAgICAg
IHdpbmRvdy5fX2p1bXBMb2FkVHJpZXMgPSAwOwogICAgICAgICAgICAgICAgaWYg
KGFsbENsaXBzLnNvbWUoYyA9PiArYy5pZCA9PT0gamlkKSkKICAgICAgICAgICAg
ICAgICAgICBzZWxlY3RlZElkID0gamlkOwogICAgICAgICAgICAgICAgc3luY0l0
ZW1IaWdobGlnaHQoKTsKICAgICAgICAgICAgfQogICAgICAgIH0KICAgICAgICBy
ZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4gewogICAgICAgICAgICBpZiAoYWxs
Q2xpcHMubGVuZ3RoIDwgZGlza1RvdGFsCiAgICAgICAgICAgICAgICAmJiBsaXN0
RWwuc2Nyb2xsSGVpZ2h0IDw9IGxpc3RFbC5jbGllbnRIZWlnaHQgKyAyMCkKICAg
ICAgICAgICAgICAgIHJlcXVlc3RNb3JlKCk7CiAgICAgICAgfSk7CiAgICB9Cgog
ICAgY29uc3QgU1ZHID0gewogICAgICAgIHRleHQ6ICAgYDxzdmcgdmlld0JveD0i
MCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ry
b2tlLXdpZHRoPSIyIj48cGF0aCBkPSJNNCA3VjRoMTZ2M005IDIwaDZNMTIgNHYx
NiIvPjwvc3ZnPmAsCiAgICAgICAgaW1hZ2U6ICBgPHN2ZyB2aWV3Qm94PSIwIDAg
MjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Ut
d2lkdGg9IjEuOCI+PHJlY3QgeD0iMyIgeT0iNSIgd2lkdGg9IjE4IiBoZWlnaHQ9
IjE0IiByeD0iMiIvPjxjaXJjbGUgY3g9IjguNSIgY3k9IjEwIiByPSIxLjUiIGZp
bGw9ImN1cnJlbnRDb2xvciIgc3Ryb2tlPSJub25lIi8+PHBhdGggZD0iTTMgMTZs
NS01IDQgNCAzLTMgNiA2Ii8+PC9zdmc+YCwKICAgICAgICBmb2xkZXI6IGA8c3Zn
IHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0iY3VycmVudENvbG9yIj48cGF0aCBk
PSJNMTAgNEg0Yy0xLjEgMC0yIC45LTIgMnYxMmMwIDEuMS45IDIgMiAyaDE2YzEu
MSAwIDItLjkgMi0yVjhjMC0xLjEtLjktMi0yLTJoLThsLTItMnoiLz48L3N2Zz5g
LAogICAgICAgIHppcDogICAgYDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxs
PSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgi
PjxwYXRoIGQ9Ik02IDNoOWw1IDV2MTNhMSAxIDAgMCAxLTEgMUg2YTEgMSAwIDAg
MS0xLTFWNGExIDEgMCAwIDEgMS0xeiIvPjxwYXRoIGQ9Ik0xNCAzdjZoNiIvPjwv
c3ZnPmAsCiAgICAgICAgYWhrOiAgICBgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQi
IGZpbGw9ImN1cnJlbnRDb2xvciI+PHRleHQgeD0iMTIiIHk9IjE3IiB0ZXh0LWFu
Y2hvcj0ibWlkZGxlIiBmb250LXNpemU9IjE0IiBmb250LXdlaWdodD0iNzAwIj5I
PC90ZXh0Pjwvc3ZnPmAsCiAgICAgICAgbG5rOiAgICBgPHN2ZyB2aWV3Qm94PSIw
IDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJv
a2Utd2lkdGg9IjEuOCI+PHBhdGggZD0iTTEwIDEzYTUgNSAwIDAgMCA3LjA3IDBs
Mi4xMi0yLjEyYTUgNSAwIDAgMC03LjA3LTcuMDdMMTEgNSIvPjxwYXRoIGQ9Ik0x
NCAxMWE1IDUgMCAwIDAtNy4wNyAwTDQuOCAxMy4xMmE1IDUgMCAxIDAgNy4wNyA3
LjA3TDEzIDE5Ii8+PC9zdmc+YCwKICAgICAgICBkb2M6ICAgIGA8c3ZnIHZpZXdC
b3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3Ii
IHN0cm9rZS13aWR0aD0iMS44Ij48cGF0aCBkPSJNNyAzaDdsNSA1djEzYTEgMSAw
IDAgMS0xIDFIN2ExIDEgMCAwIDEtMS0xVjRhMSAxIDAgMCAxIDEtMXoiLz48cGF0
aCBkPSJNMTQgM3Y2aDYiLz48L3N2Zz5gLAogICAgICAgIG11bHRpOiAgYDxzdmcg
dmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRD
b2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxyZWN0IHg9IjciIHk9IjciIHdpZHRo
PSIxMiIgaGVpZ2h0PSIxNCIgcng9IjEuNSIvPjxwYXRoIGQ9Ik01IDE3VjVhMSAx
IDAgMCAxIDEtMWgxMCIvPjwvc3ZnPmAKICAgIH07CgogICAgZnVuY3Rpb24gZmls
ZUV4dChwYXRoKSB7CiAgICAgICAgY29uc3QgYmFzZSA9IFN0cmluZyhwYXRoIHx8
ICcnKS5zcGxpdCgvW1xcL10vKS5wb3AoKSB8fCAnJzsKICAgICAgICBjb25zdCBp
ID0gYmFzZS5sYXN0SW5kZXhPZignLicpOwogICAgICAgIHJldHVybiBpID4gMCA/
IGJhc2Uuc2xpY2UoaSArIDEpLnRvTG93ZXJDYXNlKCkgOiAnJzsKICAgIH0KICAg
IGNvbnN0IGlzSW1hZ2VFeHQgPSBlID0+IFsncG5nJywnanBnJywnanBlZycsJ2dp
ZicsJ3dlYnAnLCdibXAnLCdpY28nLCd0aWYnLCd0aWZmJywnc3ZnJ10uaW5jbHVk
ZXMoZSk7CiAgICBjb25zdCBpc1ppcEV4dCAgID0gZSA9PiBbJ3ppcCcsJ3Jhcics
Jzd6JywndGFyJywnZ3onLCdiejInXS5pbmNsdWRlcyhlKTsKCiAgICBmdW5jdGlv
biBpY29uRm9yRmlsZXMoZmlsZXMpIHsKICAgICAgICBpZiAoIWZpbGVzLmxlbmd0
aCkgICAgcmV0dXJuIHsgY2xzOiAnZmlsZSBmdC1kb2MnLCBzdmc6IFNWRy5kb2Mg
fTsKICAgICAgICBpZiAoZmlsZXMubGVuZ3RoID4gMSkgcmV0dXJuIHsgY2xzOiAn
ZmlsZSBmdC1sbmsnLCBzdmc6IFNWRy5tdWx0aSB9OwogICAgICAgIGNvbnN0IGV4
dCA9IGZpbGVFeHQoZmlsZXNbMF0pOwogICAgICAgIGlmICghZXh0KSAgICAgICAg
ICAgICAgcmV0dXJuIHsgY2xzOiAnZmlsZSBmdC1kaXInLCBzdmc6IFNWRy5mb2xk
ZXIgfTsKICAgICAgICBpZiAoaXNJbWFnZUV4dChleHQpKSAgIHJldHVybiB7IGNs
czogJ2ZpbGUgZnQtaW1nJywgc3ZnOiBTVkcuaW1hZ2UgfTsKICAgICAgICBpZiAo
aXNaaXBFeHQoZXh0KSkgICAgIHJldHVybiB7IGNsczogJ2ZpbGUgZnQtemlwJywg
c3ZnOiBTVkcuemlwIH07CiAgICAgICAgaWYgKGV4dCA9PT0gJ2FoaycpICAgICBy
ZXR1cm4geyBjbHM6ICdmaWxlIGZ0LWFoaycsIHN2ZzogU1ZHLmFoayB9OwogICAg
ICAgIGlmIChleHQgPT09ICdsbmsnKSAgICAgcmV0dXJuIHsgY2xzOiAnZmlsZSBm
dC1sbmsnLCBzdmc6IFNWRy5sbmsgfTsKICAgICAgICByZXR1cm4geyBjbHM6ICdm
aWxlIGZ0LWRvYycsIHN2ZzogU1ZHLmRvYyB9OwogICAgfQoKICAgIGZ1bmN0aW9u
IGZhdkdyb3VwT2YoYykgewogICAgICAgIHJldHVybiBTdHJpbmcoYyAmJiBjLmZh
dkdyb3VwIHx8ICcnKS50cmltKCk7CiAgICB9CiAgICBmdW5jdGlvbiBjbGlwQ29u
dGVudFByZXZpZXcoYykgewogICAgICAgIGNvbnN0IHR5cGUgPSBub3JtVHlwZShj
LnR5cGUpOwogICAgICAgIGlmICh0eXBlID09PSAnaW1hZ2UnKSByZXR1cm4gJ1vl
m77lg49dJyArIChjLndpZHRoICYmIGMuaGVpZ2h0ID8gKCcgJyArIGMud2lkdGgg
KyAnw5cnICsgYy5oZWlnaHQpIDogJycpOwogICAgICAgIGlmICh0eXBlID09PSAn
ZmlsZScpIHsKICAgICAgICAgICAgY29uc3QgZmlsZXMgPSBTdHJpbmcoYy5wcmV2
aWV3IHx8IGMuZGF0YSB8fCAnJykuc3BsaXQoL1xyP1xuLykuZmlsdGVyKEJvb2xl
YW4pOwogICAgICAgICAgICByZXR1cm4gZmlsZXMubWFwKGYgPT4gZi5zcGxpdCgv
W1xcL10vKS5wb3AoKSkuam9pbignIMK3ICcpIHx8ICdb5paH5Lu2XSc7CiAgICAg
ICAgfQogICAgICAgIGlmICh0eXBlID09PSAnbGluaycpIHsKICAgICAgICAgICAg
Y29uc3QgdXJsID0gYy5kYXRhIHx8IGMucHJldmlldyB8fCAnJzsKICAgICAgICAg
ICAgY29uc3QgdGl0bGUgPSAoYy5saW5rVGl0bGUgJiYgYy5saW5rVGl0bGUgIT09
IChjLmxpbmtIb3N0IHx8IGhvc3RPZih1cmwpKSkgPyBjLmxpbmtUaXRsZSA6ICcn
OwogICAgICAgICAgICByZXR1cm4gdGl0bGUgfHwgdXJsIHx8ICdb6ZO+5o6lXSc7
CiAgICAgICAgfQogICAgICAgIHJldHVybiBTdHJpbmcoYy5wcmV2aWV3IHx8IGMu
ZGF0YSB8fCAnJyk7CiAgICB9CiAgICBmdW5jdGlvbiBidWlsZFBpbm5lZEJsb2Nr
cyhsaXN0KSB7CiAgICAgICAgY29uc3QgdXNlZCA9IG5ldyBTZXQoKTsKICAgICAg
ICBjb25zdCBvdXQgPSBbXTsKICAgICAgICBmb3IgKGNvbnN0IGMgb2YgbGlzdCkg
ewogICAgICAgICAgICBpZiAodXNlZC5oYXMoK2MuaWQpKSBjb250aW51ZTsKICAg
ICAgICAgICAgY29uc3QgZ2lkID0gZmF2R3JvdXBPZihjKTsKICAgICAgICAgICAg
aWYgKCFnaWQpIHsKICAgICAgICAgICAgICAgIHVzZWQuYWRkKCtjLmlkKTsKICAg
ICAgICAgICAgICAgIG91dC5wdXNoKHsga2luZDogJ3NpbmdsZScsIGl0ZW1zOiBb
Y10gfSk7CiAgICAgICAgICAgICAgICBjb250aW51ZTsKICAgICAgICAgICAgfQog
ICAgICAgICAgICBjb25zdCBtZW1iZXJzID0gbGlzdC5maWx0ZXIoeCA9PiBmYXZH
cm91cE9mKHgpID09PSBnaWQpOwogICAgICAgICAgICBtZW1iZXJzLmZvckVhY2go
bSA9PiB1c2VkLmFkZCgrbS5pZCkpOwogICAgICAgICAgICBpZiAobWVtYmVycy5s
ZW5ndGggPCAyKQogICAgICAgICAgICAgICAgb3V0LnB1c2goeyBraW5kOiAnc2lu
Z2xlJywgaXRlbXM6IFttZW1iZXJzWzBdIHx8IGNdIH0pOwogICAgICAgICAgICBl
bHNlCiAgICAgICAgICAgICAgICBvdXQucHVzaCh7IGtpbmQ6ICdncm91cCcsIGdp
ZCwgaXRlbXM6IG1lbWJlcnMgfSk7CiAgICAgICAgfQogICAgICAgIHJldHVybiBv
dXQ7CiAgICB9CiAgICBmdW5jdGlvbiBwYXN0ZU9uZShjKSB7CiAgICAgICAgc2Vs
ZWN0ZWRJZCA9IGMuaWQ7CiAgICAgICAgaWYgKG11bHRpSWRzLmxlbmd0aCkgY2xl
YXJNdWx0aSgpOwogICAgICAgIHN5bmNJdGVtSGlnaGxpZ2h0KCk7CiAgICAgICAg
bWFya1Bhc3RlZExvY2FsKGMuaWQpOwogICAgICAgIGFoaygncGFzdGUnLCBTdHJp
bmcoYy5pZCkpOwogICAgfQogICAgZnVuY3Rpb24gbWFrZUdyb3VwSXRlbShpdGVt
cywgaWR4KSB7CiAgICAgICAgY29uc3QgZWwgPSBkb2N1bWVudC5jcmVhdGVFbGVt
ZW50KCdkaXYnKTsKICAgICAgICBlbC5jbGFzc05hbWUgPSAnaXRtIGl0LWdyb3Vw
JwogICAgICAgICAgICArIChpdGVtcy5zb21lKGMgPT4gK2MuaWQgPT09ICtzZWxl
Y3RlZElkKSA/ICcgc2VsJyA6ICcnKQogICAgICAgICAgICArIChpdGVtcy5zb21l
KGMgPT4gbXVsdGlJZHMuaW5jbHVkZXMoK2MuaWQpKSA/ICcgbXVsdGknIDogJycp
OwogICAgICAgIGVsLmRhdGFzZXQuZ3JvdXAgPSBmYXZHcm91cE9mKGl0ZW1zWzBd
KSB8fCAnJzsKICAgICAgICBlbC5kYXRhc2V0LmlkID0gaXRlbXNbMF0uaWQ7Cgog
ICAgICAgIGNvbnN0IGhlYWQgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYn
KTsKICAgICAgICBoZWFkLmNsYXNzTmFtZSA9ICdtZy1oZWFkJzsKICAgICAgICBo
ZWFkLmlubmVySFRNTCA9ICc8c3BhbiBjbGFzcz0ibWctdGFnIj7lkIjlubY8L3Nw
YW4+PHNwYW4+JyArIGl0ZW1zLmxlbmd0aCArICcg5p2hIMK3IOeCueWHu+WNlead
oeeymOi0tDwvc3Bhbj4nOwogICAgICAgIGVsLmFwcGVuZENoaWxkKGhlYWQpOwoK
ICAgICAgICBpdGVtcy5mb3JFYWNoKGMgPT4gewogICAgICAgICAgICBjb25zdCBy
b3cgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAg
cm93LmNsYXNzTmFtZSA9ICdtZy1yb3cnCiAgICAgICAgICAgICAgICArICgrc2Vs
ZWN0ZWRJZCA9PT0gK2MuaWQgPyAnIHNlbCcgOiAnJykKICAgICAgICAgICAgICAg
ICsgKG11bHRpSWRzLmluY2x1ZGVzKCtjLmlkKSA/ICcgbXVsdGknIDogJycpOwog
ICAgICAgICAgICByb3cuZGF0YXNldC5pZCA9IGMuaWQ7CgogICAgICAgICAgICBj
b25zdCB0b3AgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAg
ICAgICAgdG9wLmNsYXNzTmFtZSA9ICdtZy1yb3ctdG9wJzsKICAgICAgICAgICAg
Y29uc3QgbWFpbiA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAg
ICAgICAgICBtYWluLmNsYXNzTmFtZSA9ICdtZy1yb3ctbWFpbic7CgogICAgICAg
ICAgICBjb25zdCB0aXRsZSA9IFN0cmluZyhjLmZhdlRpdGxlIHx8ICcnKS50cmlt
KCk7CiAgICAgICAgICAgIGlmICh0aXRsZSkgewogICAgICAgICAgICAgICAgY29u
c3QgdCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAg
ICAgICAgdC5jbGFzc05hbWUgPSAnbWctdGl0bGUnOwogICAgICAgICAgICAgICAg
dC50ZXh0Q29udGVudCA9IHRpdGxlOwogICAgICAgICAgICAgICAgbWFpbi5hcHBl
bmRDaGlsZCh0KTsKICAgICAgICAgICAgfQogICAgICAgICAgICBjb25zdCBib2R5
ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIGJv
ZHkuY2xhc3NOYW1lID0gJ21nLWJvZHknICsgKG5vcm1UeXBlKGMudHlwZSkgPT09
ICdpbWFnZScgPyAnIGltZycgOiAnJyk7CiAgICAgICAgICAgIGJvZHkudGV4dENv
bnRlbnQgPSBjbGlwQ29udGVudFByZXZpZXcoYyk7CiAgICAgICAgICAgIG1haW4u
YXBwZW5kQ2hpbGQoYm9keSk7CiAgICAgICAgICAgIHRvcC5hcHBlbmRDaGlsZCht
YWluKTsKCiAgICAgICAgICAgIGNvbnN0IHNyY0ljbyA9IFN0cmluZyhjLnNyY0lj
b24gfHwgJycpOwogICAgICAgICAgICBjb25zdCBzcmNFeGUgPSBTdHJpbmcoYy5z
cmNFeGUgfHwgJycpOwogICAgICAgICAgICBpZiAoc3JjSWNvKSB7CiAgICAgICAg
ICAgICAgICBjb25zdCBpbWcgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdpbWcn
KTsKICAgICAgICAgICAgICAgIGltZy5jbGFzc05hbWUgPSAnbWctc3JjJzsKICAg
ICAgICAgICAgICAgIGltZy5zcmMgPSBTVE9SRV9CQVNFICsgZW5jb2RlVVJJQ29t
cG9uZW50KHNyY0ljbyk7CiAgICAgICAgICAgICAgICBpbWcuYWx0ID0gJyc7CiAg
ICAgICAgICAgICAgICBpbWcudGl0bGUgPSBzcmNFeGUgfHwgJ+mPieODpuewric7
CiAgICAgICAgICAgICAgICB0b3AuYXBwZW5kQ2hpbGQoaW1nKTsKICAgICAgICAg
ICAgfQogICAgICAgICAgICByb3cuYXBwZW5kQ2hpbGQodG9wKTsKCiAgICAgICAg
ICAgIHJvdy5vbmNsaWNrID0gZSA9PiB7CiAgICAgICAgICAgICAgICBlLnByZXZl
bnREZWZhdWx0KCk7CiAgICAgICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigp
OwogICAgICAgICAgICAgICAgaWYgKGUuY3RybEtleSB8fCBlLm1ldGFLZXkpIHsK
ICAgICAgICAgICAgICAgICAgICB0b2dnbGVNdWx0aShjLmlkKTsKICAgICAgICAg
ICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAg
ICAgICBwYXN0ZU9uZShjKTsKICAgICAgICAgICAgfTsKICAgICAgICAgICAgcm93
Lm9uY29udGV4dG1lbnUgPSBlID0+IHsKICAgICAgICAgICAgICAgIGUucHJldmVu
dERlZmF1bHQoKTsKICAgICAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7
CiAgICAgICAgICAgICAgICBzZWxlY3RlZElkID0gYy5pZDsKICAgICAgICAgICAg
ICAgIHNob3dDdHgoZS5jbGllbnRYLCBlLmNsaWVudFksIGMpOwogICAgICAgICAg
ICB9OwogICAgICAgICAgICBlbC5hcHBlbmRDaGlsZChyb3cpOwogICAgICAgIH0p
OwoKICAgICAgICBlbC5vbmNvbnRleHRtZW51ID0gZSA9PiB7CiAgICAgICAgICAg
IGlmIChlLnRhcmdldC5jbG9zZXN0KCcubWctcm93JykpIHJldHVybjsKICAgICAg
ICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICBzZWxlY3RlZElk
ID0gaXRlbXNbMF0uaWQ7CiAgICAgICAgICAgIHNob3dDdHgoZS5jbGllbnRYLCBl
LmNsaWVudFksIGl0ZW1zWzBdKTsKICAgICAgICB9OwogICAgICAgIHJldHVybiBl
bDsKICAgIH0KCiAgICBmdW5jdGlvbiBtYWtlSXRlbShjLCBpZHgpIHsKICAgICAg
ICBjb25zdCB0eXBlICAgPSBub3JtVHlwZShjLnR5cGUpOwogICAgICAgIGNvbnN0
IHBpbm5lZCA9IGlzUGlubmVkKGMpOwogICAgICAgIGNvbnN0IHBhc3RlZCA9IGlz
UGFzdGVkKGMpOwogICAgICAgIGNvbnN0IGVsICAgICA9IGRvY3VtZW50LmNyZWF0
ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgIGVsLmNsYXNzTmFtZSAgPSAnaXRtJwog
ICAgICAgICAgICArIChzZWxlY3RlZElkID09IGMuaWQgPyAnIHNlbCcgOiAnJykK
ICAgICAgICAgICAgKyAobXVsdGlJZHMuaW5jbHVkZXMoK2MuaWQpID8gJyBtdWx0
aScgOiAnJyk7CiAgICAgICAgZWwuZGF0YXNldC5pZCA9IGMuaWQ7CgogICAgICAg
IGNvbnN0IGljbyAgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAg
ICAgICBjb25zdCBib2R5ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7
CiAgICAgICAgYm9keS5jbGFzc05hbWUgPSAnaS1ib2R5JzsKCiAgICAgICAgaWYg
KHR5cGUgPT09ICdpbWFnZScpIHsKICAgICAgICAgICAgaWNvLmNsYXNzTmFtZSA9
ICdpLWljbyBpbWFnZSc7CiAgICAgICAgICAgIGljby5pbm5lckhUTUwgPSBTVkcu
aW1hZ2U7CiAgICAgICAgICAgIGNvbnN0IHdyYXAgPSBkb2N1bWVudC5jcmVhdGVF
bGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgd3JhcC5jbGFzc05hbWUgPSAnaS10
aHVtYi13cmFwJzsKICAgICAgICAgICAgY29uc3QgaW1nICA9IGRvY3VtZW50LmNy
ZWF0ZUVsZW1lbnQoJ2ltZycpOwogICAgICAgICAgICBpbWcuY2xhc3NOYW1lID0g
J2ktdGh1bWInOwogICAgICAgICAgICBpbWcuYWx0ID0gJyc7CiAgICAgICAgICAg
IGNvbnN0IGZpbGUgPSBTdHJpbmcoYy5pbWdGaWxlIHx8ICcnKTsKICAgICAgICAg
ICAgbGV0IGZhbGxiYWNrID0gU3RyaW5nKGMuZGF0YSB8fCAnJyk7CiAgICAgICAg
ICAgIC8vIFN5bmMgbG9hZCBmcm9tIEFISyAoc2FtZSBwYXR0ZXJuIGFzIGZpbGUg
ZW5zdXJlRmlsZUltZykg4oCUIGF2b2lkcyBWSC9yYWNlIG1pc3MKICAgICAgICAg
ICAgaWYgKCFmYWxsYmFjay5zdGFydHNXaXRoKCdkYXRhOicpKSB7CiAgICAgICAg
ICAgICAgICB0cnkgewogICAgICAgICAgICAgICAgICAgIGNvbnN0IGdvdCA9IGFo
a1JldCgndGh1bWInLCBTdHJpbmcoYy5pZCkpOwogICAgICAgICAgICAgICAgICAg
IGlmIChnb3QgJiYgU3RyaW5nKGdvdCkuc3RhcnRzV2l0aCgnZGF0YTonKSkKICAg
ICAgICAgICAgICAgICAgICAgICAgZmFsbGJhY2sgPSBTdHJpbmcoZ290KTsKICAg
ICAgICAgICAgICAgIH0gY2F0Y2gge30KICAgICAgICAgICAgfQogICAgICAgICAg
ICBpZiAoIWZhbGxiYWNrLnN0YXJ0c1dpdGgoJ2RhdGE6JykgJiYgdGh1bWJDYWNo
ZS5oYXMoU3RyaW5nKGMuaWQpKSkKICAgICAgICAgICAgICAgIGZhbGxiYWNrID0g
U3RyaW5nKHRodW1iQ2FjaGUuZ2V0KFN0cmluZyhjLmlkKSkpOwogICAgICAgICAg
ICBpbWcub25sb2FkID0gKCkgPT4gewogICAgICAgICAgICAgICAgY29uc3QgbXcg
PSB3cmFwLmNsaWVudFdpZHRoIHx8IDMwMDsKICAgICAgICAgICAgICAgIGNvbnN0
IG53ID0gaW1nLm5hdHVyYWxXaWR0aCAgfHwgMDsKICAgICAgICAgICAgICAgIGNv
bnN0IG5oID0gaW1nLm5hdHVyYWxIZWlnaHQgfHwgMDsKICAgICAgICAgICAgICAg
IGlmICghbncgfHwgIW5oKSByZXR1cm47CiAgICAgICAgICAgICAgICBjb25zdCBz
Y2FsZSA9IE1hdGgubWluKDEsIDE4MCAvIG5oLCBtdyAvIG53KTsKICAgICAgICAg
ICAgICAgIGltZy5zdHlsZS53aWR0aCAgPSBNYXRoLnJvdW5kKG53ICogc2NhbGUp
ICsgJ3B4JzsKICAgICAgICAgICAgICAgIGltZy5zdHlsZS5oZWlnaHQgPSBNYXRo
LnJvdW5kKG5oICogc2NhbGUpICsgJ3B4JzsKICAgICAgICAgICAgfTsKICAgICAg
ICAgICAgYmluZFN0b3JlVGh1bWIoaW1nLCBmaWxlLCBjLmlkLCBmYWxsYmFjayk7
CiAgICAgICAgICAgIHdyYXAuYXBwZW5kQ2hpbGQoaW1nKTsKICAgICAgICAgICAg
Y29uc3QgbWV0YSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAg
ICAgICAgICBtZXRhLmNsYXNzTmFtZSA9ICdpLW1ldGEnOwogICAgICAgICAgICBt
ZXRhLmlubmVySFRNTCAgPSBgPHNwYW4gY2xhc3M9ImktdGltZSI+JHthZ28oYy50
aW1lKX08L3NwYW4+JHttZXRhQ2VudGVySHRtbChmYWxzZSl9PGRpdiBjbGFzcz0i
aS1tZXRhLXJpZ2h0Ij4ke2Mud2lkdGggPyBgPHNwYW4gY2xhc3M9ImktdGFnIj4k
e2Mud2lkdGh9w5cke2MuaGVpZ2h0fSBweDwvc3Bhbj5gIDogJyd9PC9kaXY+YDsK
ICAgICAgICAgICAgYm9keS5hcHBlbmRDaGlsZCh3cmFwKTsKICAgICAgICAgICAg
Ym9keS5hcHBlbmRDaGlsZChtZXRhKTsKICAgICAgICB9IGVsc2UgaWYgKHR5cGUg
PT09ICdmaWxlJykgewogICAgICAgICAgICBjb25zdCBmaWxlcyA9IFN0cmluZyhj
LnByZXZpZXcgfHwgYy5kYXRhIHx8ICcnKS5zcGxpdCgvXHI/XG4vKS5maWx0ZXIo
Qm9vbGVhbik7CiAgICAgICAgICAgIGNvbnN0IGltYWdlUGF0aHMgPSBmaWxlcy5m
aWx0ZXIoZiA9PiBpc0ltYWdlRXh0KGZpbGVFeHQoZikpKTsKICAgICAgICAgICAg
Y29uc3QgaWMgICAgPSBpY29uRm9yRmlsZXMoZmlsZXMpOwogICAgICAgICAgICBp
Y28uY2xhc3NOYW1lID0gJ2ktaWNvICcgKyBpYy5jbHM7CiAgICAgICAgICAgIGlj
by5pbm5lckhUTUwgPSBpYy5zdmc7CgogICAgICAgICAgICBsZXQgdGh1bWJGaWxl
ID0gU3RyaW5nKGMuaW1nRmlsZSB8fCAnJyk7CiAgICAgICAgICAgIGlmICghdGh1
bWJGaWxlICYmIGltYWdlUGF0aHMubGVuZ3RoKSB7CiAgICAgICAgICAgICAgICB0
cnkgewogICAgICAgICAgICAgICAgICAgIGNvbnN0IGdvdCA9IGFoa1JldCgnZW5z
dXJlRmlsZUltZycsIGltYWdlUGF0aHNbMF0sIFN0cmluZyhjLmlkKSk7CiAgICAg
ICAgICAgICAgICAgICAgaWYgKGdvdCkgewogICAgICAgICAgICAgICAgICAgICAg
ICB0aHVtYkZpbGUgPSBTdHJpbmcoZ290KTsKICAgICAgICAgICAgICAgICAgICAg
ICAgYy5pbWdGaWxlID0gdGh1bWJGaWxlOwogICAgICAgICAgICAgICAgICAgIH0K
ICAgICAgICAgICAgICAgIH0gY2F0Y2gge30KICAgICAgICAgICAgfQoKICAgICAg
ICAgICAgLy8gSW1hZ2UtZm9ybWF0IGZpbGVzOiBzYW1lIHRodW1ibmFpbCBydWxl
cyBhcyBzY3JlZW5zaG90IGNsaXBzCiAgICAgICAgICAgIGlmICh0aHVtYkZpbGUg
fHwgaW1hZ2VQYXRocy5sZW5ndGgpIHsKICAgICAgICAgICAgICAgIGNvbnN0IHdy
YXAgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAg
ICAgIHdyYXAuY2xhc3NOYW1lID0gJ2ktdGh1bWItd3JhcCc7CiAgICAgICAgICAg
ICAgICBjb25zdCBpbWcgID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnaW1nJyk7
CiAgICAgICAgICAgICAgICBpbWcuY2xhc3NOYW1lID0gJ2ktdGh1bWInOwogICAg
ICAgICAgICAgICAgaW1nLmFsdCA9ICcnOwogICAgICAgICAgICAgICAgaW1nLm9u
bG9hZCA9ICgpID0+IHsKICAgICAgICAgICAgICAgICAgICBjb25zdCBtdyA9IHdy
YXAuY2xpZW50V2lkdGggfHwgMzAwOwogICAgICAgICAgICAgICAgICAgIGNvbnN0
IG53ID0gaW1nLm5hdHVyYWxXaWR0aCAgfHwgMDsKICAgICAgICAgICAgICAgICAg
ICBjb25zdCBuaCA9IGltZy5uYXR1cmFsSGVpZ2h0IHx8IDA7CiAgICAgICAgICAg
ICAgICAgICAgaWYgKCFudyB8fCAhbmgpIHJldHVybjsKICAgICAgICAgICAgICAg
ICAgICBjb25zdCBzY2FsZSA9IE1hdGgubWluKDEsIDE4MCAvIG5oLCBtdyAvIG53
KTsKICAgICAgICAgICAgICAgICAgICBpbWcuc3R5bGUud2lkdGggID0gTWF0aC5y
b3VuZChudyAqIHNjYWxlKSArICdweCc7CiAgICAgICAgICAgICAgICAgICAgaW1n
LnN0eWxlLmhlaWdodCA9IE1hdGgucm91bmQobmggKiBzY2FsZSkgKyAncHgnOwog
ICAgICAgICAgICAgICAgfTsKICAgICAgICAgICAgICAgIGlmICghdGh1bWJGaWxl
ICYmIGltYWdlUGF0aHMubGVuZ3RoKSB7CiAgICAgICAgICAgICAgICAgICAgdHJ5
IHsKICAgICAgICAgICAgICAgICAgICAgICAgY29uc3QgZ290ID0gYWhrUmV0KCdl
bnN1cmVGaWxlSW1nJywgaW1hZ2VQYXRoc1swXSwgU3RyaW5nKGMuaWQpKTsKICAg
ICAgICAgICAgICAgICAgICAgICAgaWYgKGdvdCkgewogICAgICAgICAgICAgICAg
ICAgICAgICAgICAgdGh1bWJGaWxlID0gU3RyaW5nKGdvdCk7CiAgICAgICAgICAg
ICAgICAgICAgICAgICAgICBjLmltZ0ZpbGUgPSB0aHVtYkZpbGU7CiAgICAgICAg
ICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgICAgICB9IGNhdGNoIHt9
CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICBiaW5kU3RvcmVUaHVt
YihpbWcsIHRodW1iRmlsZSwgYy5pZCwgJycpOwogICAgICAgICAgICAgICAgd3Jh
cC5hcHBlbmRDaGlsZChpbWcpOwogICAgICAgICAgICAgICAgYm9keS5hcHBlbmRD
aGlsZCh3cmFwKTsKICAgICAgICAgICAgfQoKICAgICAgICAgICAgY29uc3QgbmFt
ZSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBu
YW1lLmNsYXNzTmFtZSAgPSAnaS1uYW1lJzsKICAgICAgICAgICAgbmFtZS50ZXh0
Q29udGVudCA9IGZpbGVzLm1hcChmID0+IGYuc3BsaXQoL1tcXC9dLykucG9wKCkp
LmpvaW4oJ1xuJykgfHwgJyjmlofku7YpJzsKCiAgICAgICAgICAgIC8vIFN0cmlr
ZSBsaXN0IGVudHJ5IG9ubHkgd2hlbiBldmVyeSBwYXRoIGlzIGdvbmUgKG11bHRp
LWZpbGU6IGFsbCBtaXNzaW5nKQogICAgICAgICAgICBjb25zdCBwYXRoUm93cyA9
IGNoZWNrRmlsZVBhdGhzKGZpbGVzKTsKICAgICAgICAgICAgY29uc3QgYWxsR29u
ZSA9IHBhdGhSb3dzLmxlbmd0aCA+IDAgJiYgcGF0aFJvd3MuZXZlcnkociA9PiBy
LmV4aXN0cyA9PT0gZmFsc2UpOwogICAgICAgICAgICBpZiAoYWxsR29uZSkKICAg
ICAgICAgICAgICAgIGVsLmNsYXNzTGlzdC5hZGQoJ2dvbmUnKTsKCiAgICAgICAg
ICAgIGNvbnN0IGRldGFpbCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2Rpdicp
OwogICAgICAgICAgICBkZXRhaWwuY2xhc3NOYW1lID0gJ2ktZmlsZS1kZXRhaWwn
OwoKICAgICAgICAgICAgY29uc3QgbWV0YSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1l
bnQoJ2RpdicpOwogICAgICAgICAgICBtZXRhLmNsYXNzTmFtZSA9ICdpLW1ldGEn
OwogICAgICAgICAgICBsZXQgcmlnaHQgPSBgPHNwYW4gY2xhc3M9ImktdGFnIj4k
e2MuZmlsZUNvdW50IHx8IGZpbGVzLmxlbmd0aCB8fCAxfSDkuKrmlofku7Y8L3Nw
YW4+YDsKICAgICAgICAgICAgaWYgKCh0aHVtYkZpbGUgfHwgaW1hZ2VQYXRocy5s
ZW5ndGgpICYmIGMud2lkdGgpCiAgICAgICAgICAgICAgICByaWdodCA9IGA8c3Bh
biBjbGFzcz0iaS10YWciPiR7Yy53aWR0aH3DlyR7Yy5oZWlnaHR9IHB4PC9zcGFu
PmAgKyByaWdodDsKICAgICAgICAgICAgY29uc3QgZXhwYW5kSHRtbCA9CiAgICAg
ICAgICAgICAgICBgPHN2ZyB2aWV3Qm94PSIwIDAgMTYgMTYiIHdpZHRoPSIxMCIg
aGVpZ2h0PSIxMCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0
cm9rZS13aWR0aD0iMS44IiBzdHJva2UtbGluZWNhcD0icm91bmQiPmAgKwogICAg
ICAgICAgICAgICAgYDxwb2x5bGluZSBwb2ludHM9IjQgNiA4IDEwIDEyIDYiLz48
L3N2Zz7lsZXlvIBgOwogICAgICAgICAgICBjb25zdCBjb2xsYXBzZUh0bWwgPQog
ICAgICAgICAgICAgICAgYDxzdmcgdmlld0JveD0iMCAwIDE2IDE2IiB3aWR0aD0i
MTAiIGhlaWdodD0iMTAiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9y
IiBzdHJva2Utd2lkdGg9IjEuOCIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIj5gICsK
ICAgICAgICAgICAgICAgIGA8cG9seWxpbmUgcG9pbnRzPSI0IDEwIDggNiAxMiAx
MCIvPjwvc3ZnPuaUtui1t2A7CiAgICAgICAgICAgIG1ldGEuaW5uZXJIVE1MID0K
ICAgICAgICAgICAgICAgIGA8c3BhbiBjbGFzcz0iaS10aW1lIj4ke2FnbyhjLnRp
bWUpfTwvc3Bhbj5gICsKICAgICAgICAgICAgICAgIG1ldGFDZW50ZXJIdG1sKHsg
b246IHRydWUsIGh0bWw6IGV4cGFuZEh0bWwgfSkgKwogICAgICAgICAgICAgICAg
YDxkaXYgY2xhc3M9ImktbWV0YS1yaWdodCI+JHtyaWdodH08L2Rpdj5gOwoKICAg
ICAgICAgICAgY29uc3QgZXhwQnRuID0gbWV0YS5xdWVyeVNlbGVjdG9yKCcuaS1l
eHBhbmQtYnRuJyk7CiAgICAgICAgICAgIGxldCBkZXRhaWxCdWlsdCA9IGZhbHNl
OwogICAgICAgICAgICBleHBCdG4ub25jbGljayA9IGUgPT4gewogICAgICAgICAg
ICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICAgICAgZS5zdG9w
UHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgIGNvbnN0IG9wZW4gPSAhZGV0
YWlsLmNsYXNzTGlzdC5jb250YWlucygnb24nKTsKICAgICAgICAgICAgICAgIGlm
IChvcGVuICYmICFkZXRhaWxCdWlsdCkgewogICAgICAgICAgICAgICAgICAgIGZp
bGxGaWxlRGV0YWlsUGFuZWwoZGV0YWlsLCBwYXRoUm93cyk7CiAgICAgICAgICAg
ICAgICAgICAgZGV0YWlsQnVpbHQgPSB0cnVlOwogICAgICAgICAgICAgICAgfQog
ICAgICAgICAgICAgICAgZGV0YWlsLmNsYXNzTGlzdC50b2dnbGUoJ29uJywgb3Bl
bik7CiAgICAgICAgICAgICAgICBleHBCdG4uaW5uZXJIVE1MID0gb3BlbiA/IGNv
bGxhcHNlSHRtbCA6IGV4cGFuZEh0bWw7CiAgICAgICAgICAgIH07CgogICAgICAg
ICAgICBib2R5LmFwcGVuZENoaWxkKG5hbWUpOwogICAgICAgICAgICBib2R5LmFw
cGVuZENoaWxkKGRldGFpbCk7CiAgICAgICAgICAgIGJvZHkuYXBwZW5kQ2hpbGQo
bWV0YSk7CiAgICAgICAgfSBlbHNlIGlmICh0eXBlID09PSAnbGluaycpIHsKICAg
ICAgICAgICAgY29uc3QgdXJsICA9IGMuZGF0YSB8fCBjLnByZXZpZXcgfHwgJyc7
CiAgICAgICAgICAgIGNvbnN0IGhvc3QgPSBjLmxpbmtIb3N0IHx8IGhvc3RPZih1
cmwpOwogICAgICAgICAgICBjb25zdCB0aXRsZSA9IChjLmxpbmtUaXRsZSAmJiBj
LmxpbmtUaXRsZSAhPT0gaG9zdCkgPyBjLmxpbmtUaXRsZSA6ICcnOwogICAgICAg
ICAgICBpY28uY2xhc3NOYW1lID0gJ2ktaWNvIGxpbmsnOwogICAgICAgICAgICBp
Y28uaW5uZXJIVE1MID0gU1ZHLmxuazsKCiAgICAgICAgICAgIC8vIEZhdmljb24g
b25seSB3aGlsZSDpk77mjqUgdGFiIGlzIGFjdGl2ZSDigJQgY2FuY2VsbGVkIG9u
IHRhYiBzd2l0Y2gKICAgICAgICAgICAgaWYgKGN1clRhYiA9PT0gJ2xpbmsnICYm
IGxpbmtMb2FkQWN0aXZlICYmIGhvc3QpIHsKICAgICAgICAgICAgICAgIGNvbnN0
IGZpID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnaW1nJyk7CiAgICAgICAgICAg
ICAgICBmaS5hbHQgPSAnJzsKICAgICAgICAgICAgICAgIGZpLmRlY29kaW5nID0g
J2FzeW5jJzsKICAgICAgICAgICAgICAgIGZpLmxvYWRpbmcgPSAnbGF6eSc7CiAg
ICAgICAgICAgICAgICBpY28uaW5uZXJIVE1MID0gU1ZHLmxuazsKICAgICAgICAg
ICAgICAgIGljby5hcHBlbmRDaGlsZChmaSk7CiAgICAgICAgICAgICAgICBmaS5z
dHlsZS5wb3NpdGlvbiA9ICdhYnNvbHV0ZSc7CiAgICAgICAgICAgICAgICByZXF1
ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4gewogICAgICAgICAgICAgICAgICAgIGlm
ICghbGlua0xvYWRBY3RpdmUgfHwgIWZpLmlzQ29ubmVjdGVkKSByZXR1cm47CiAg
ICAgICAgICAgICAgICAgICAgZmkub25lcnJvciA9ICgpID0+IHsgaWYgKGZpLmlz
Q29ubmVjdGVkKSBmaS5yZW1vdmUoKTsgfTsKICAgICAgICAgICAgICAgICAgICBm
aS5vbmxvYWQgPSAoKSA9PiB7CiAgICAgICAgICAgICAgICAgICAgICAgIGlmICgh
ZmkuaXNDb25uZWN0ZWQpIHJldHVybjsKICAgICAgICAgICAgICAgICAgICAgICAg
Ly8gUmVwbGFjZSBkZWZhdWx0IHN2ZyB3aXRoIGZhdmljb24gd2hlbiBsb2FkZWQK
ICAgICAgICAgICAgICAgICAgICAgICAgY29uc3Qgc3ZnID0gaWNvLnF1ZXJ5U2Vs
ZWN0b3IoJ3N2ZycpOwogICAgICAgICAgICAgICAgICAgICAgICBpZiAoc3ZnKSBz
dmcucmVtb3ZlKCk7CiAgICAgICAgICAgICAgICAgICAgICAgIGZpLnN0eWxlLnBv
c2l0aW9uID0gJyc7CiAgICAgICAgICAgICAgICAgICAgfTsKICAgICAgICAgICAg
ICAgICAgICBmaS5zcmMgPSBmYXZpY29uVXJsKGhvc3QpOwogICAgICAgICAgICAg
ICAgfSk7CiAgICAgICAgICAgIH0KCiAgICAgICAgICAgIGNvbnN0IGNhcmQgPSBk
b2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgY2FyZC5j
bGFzc05hbWUgPSAnaS1saW5rLWNhcmQnOwoKICAgICAgICAgICAgaWYgKHRpdGxl
KSB7CiAgICAgICAgICAgICAgICBjb25zdCB0aXRsZUVsID0gZG9jdW1lbnQuY3Jl
YXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgICAgICB0aXRsZUVsLmNsYXNz
TmFtZSA9ICdpLWxpbmstdGl0bGUnOwogICAgICAgICAgICAgICAgdGl0bGVFbC50
ZXh0Q29udGVudCA9IHRpdGxlOwogICAgICAgICAgICAgICAgY2FyZC5hcHBlbmRD
aGlsZCh0aXRsZUVsKTsKICAgICAgICAgICAgfQoKICAgICAgICAgICAgY29uc3Qg
dXJsRWwgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAg
ICAgdXJsRWwuY2xhc3NOYW1lID0gJ2ktbGluay11cmwnOwogICAgICAgICAgICB1
cmxFbC50ZXh0Q29udGVudCA9IHVybDsKICAgICAgICAgICAgY2FyZC5hcHBlbmRD
aGlsZCh1cmxFbCk7CgogICAgICAgICAgICAvLyBBY3Rpb25zIG9uIHRoZWlyIG93
biByb3cgKGFib3ZlIG1ldGEpIHNvIG1ldGEgc3RheXMgYWxpZ25lZAogICAgICAg
ICAgICBjb25zdCBhY3Rpb25zID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2
Jyk7CiAgICAgICAgICAgIGFjdGlvbnMuY2xhc3NOYW1lID0gJ2ktbGluay1hY3Rp
b25zJzsKICAgICAgICAgICAgY29uc3Qgb3BlbkJ0biA9IGRvY3VtZW50LmNyZWF0
ZUVsZW1lbnQoJ2J1dHRvbicpOwogICAgICAgICAgICBvcGVuQnRuLnR5cGUgPSAn
YnV0dG9uJzsKICAgICAgICAgICAgb3BlbkJ0bi5jbGFzc05hbWUgPSAnaS1vcGVu
LWJ0bic7CiAgICAgICAgICAgIG9wZW5CdG4udGV4dENvbnRlbnQgPSAn5omT5byA
JzsKICAgICAgICAgICAgb3BlbkJ0bi5vbmNsaWNrID0gZSA9PiB7CiAgICAgICAg
ICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgICAgICBlLnN0
b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAgc3RvcExpbmtNZWRpYSgp
OwogICAgICAgICAgICAgICAgYWhrKCdvcGVuTGluaycsIFN0cmluZyhjLmlkKSk7
CiAgICAgICAgICAgIH07CiAgICAgICAgICAgIGFjdGlvbnMuYXBwZW5kQ2hpbGQo
b3BlbkJ0bik7CiAgICAgICAgICAgIGlmIChmaW5kU291cmNlQ2xpcCh1cmwpKSB7
CiAgICAgICAgICAgICAgICBjb25zdCBzcmNCdG4gPSBkb2N1bWVudC5jcmVhdGVF
bGVtZW50KCdidXR0b24nKTsKICAgICAgICAgICAgICAgIHNyY0J0bi50eXBlID0g
J2J1dHRvbic7CiAgICAgICAgICAgICAgICBzcmNCdG4uY2xhc3NOYW1lID0gJ2kt
c3JjLWJ0bic7CiAgICAgICAgICAgICAgICBzcmNCdG4udGV4dENvbnRlbnQgPSAn
5Y6f5paHJzsKICAgICAgICAgICAgICAgIHNyY0J0bi50aXRsZSA9ICfot7Povazl
iLDlhajpg6jkuK3nmoTljp/mtojmga8nOwogICAgICAgICAgICAgICAgc3JjQnRu
Lm9uY2xpY2sgPSBlID0+IHsKICAgICAgICAgICAgICAgICAgICBlLnByZXZlbnRE
ZWZhdWx0KCk7CiAgICAgICAgICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24o
KTsKICAgICAgICAgICAgICAgICAgICBqdW1wVG9Tb3VyY2UodXJsKTsKICAgICAg
ICAgICAgICAgIH07CiAgICAgICAgICAgICAgICBhY3Rpb25zLmFwcGVuZENoaWxk
KHNyY0J0bik7CiAgICAgICAgICAgIH0KICAgICAgICAgICAgY2FyZC5hcHBlbmRD
aGlsZChhY3Rpb25zKTsKCiAgICAgICAgICAgIC8vIFByZXZpZXc6IG9ubHkgaW5z
ZXJ0IGludG8gRE9NIGFmdGVyIGEgcmVhbCBub24tYmxhbmsgaW1hZ2UgbG9hZHMK
ICAgICAgICAgICAgaWYgKGN1clRhYiA9PT0gJ2xpbmsnKSB7CiAgICAgICAgICAg
ICAgICByZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4gewogICAgICAgICAgICAg
ICAgICAgIGlmICghbGlua0xvYWRBY3RpdmUgfHwgIWNhcmQuaXNDb25uZWN0ZWQp
IHJldHVybjsKICAgICAgICAgICAgICAgICAgICBjb25zdCBpbyA9IG5ldyBJbnRl
cnNlY3Rpb25PYnNlcnZlcihlbnRyaWVzID0+IHsKICAgICAgICAgICAgICAgICAg
ICAgICAgaWYgKCFsaW5rTG9hZEFjdGl2ZSkgeyBpby5kaXNjb25uZWN0KCk7IHJl
dHVybjsgfQogICAgICAgICAgICAgICAgICAgICAgICBpZiAoIWVudHJpZXMuc29t
ZShlID0+IGUuaXNJbnRlcnNlY3RpbmcpKSByZXR1cm47CiAgICAgICAgICAgICAg
ICAgICAgICAgIGlvLmRpc2Nvbm5lY3QoKTsKICAgICAgICAgICAgICAgICAgICAg
ICAgbGlua09ic2VydmVycyA9IGxpbmtPYnNlcnZlcnMuZmlsdGVyKHggPT4geCAh
PT0gaW8pOwogICAgICAgICAgICAgICAgICAgICAgICBpZiAoIWxpbmtMb2FkQWN0
aXZlIHx8ICFjYXJkLmlzQ29ubmVjdGVkKSByZXR1cm47CiAgICAgICAgICAgICAg
ICAgICAgICAgIGNvbnN0IHNob3RJbWcgPSBuZXcgSW1hZ2UoKTsKICAgICAgICAg
ICAgICAgICAgICAgICAgc2hvdEltZy5hbHQgPSAnJzsKICAgICAgICAgICAgICAg
ICAgICAgICAgc2hvdEltZy5kZWNvZGluZyA9ICdhc3luYyc7CiAgICAgICAgICAg
ICAgICAgICAgICAgIGxldCBzZXR0bGVkID0gZmFsc2U7CiAgICAgICAgICAgICAg
ICAgICAgICAgIGNvbnN0IHJlamVjdCA9ICgpID0+IHsgc2V0dGxlZCA9IHRydWU7
IH07CiAgICAgICAgICAgICAgICAgICAgICAgIHNob3RJbWcub25lcnJvciA9IHJl
amVjdDsKICAgICAgICAgICAgICAgICAgICAgICAgc2hvdEltZy5vbmxvYWQgPSAo
KSA9PiB7CiAgICAgICAgICAgICAgICAgICAgICAgICAgICBzZXR0bGVkID0gdHJ1
ZTsKICAgICAgICAgICAgICAgICAgICAgICAgICAgIGlmICghbGlua0xvYWRBY3Rp
dmUgfHwgIWNhcmQuaXNDb25uZWN0ZWQpIHJldHVybjsKICAgICAgICAgICAgICAg
ICAgICAgICAgICAgIGlmIChzaG90SW1nLm5hdHVyYWxXaWR0aCA8IDQ4IHx8IHNo
b3RJbWcubmF0dXJhbEhlaWdodCA8IDMyKSByZXR1cm47CiAgICAgICAgICAgICAg
ICAgICAgICAgICAgICBjb25zdCBzaG90ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVu
dCgnZGl2Jyk7CiAgICAgICAgICAgICAgICAgICAgICAgICAgICBzaG90LmNsYXNz
TmFtZSA9ICdpLWxpbmstc2hvdCc7CiAgICAgICAgICAgICAgICAgICAgICAgICAg
ICBzaG90LmFwcGVuZENoaWxkKHNob3RJbWcpOwogICAgICAgICAgICAgICAgICAg
ICAgICAgICAgY29uc3QgYWN0RWwgPSBjYXJkLnF1ZXJ5U2VsZWN0b3IoJy5pLWxp
bmstYWN0aW9ucycpOwogICAgICAgICAgICAgICAgICAgICAgICAgICAgaWYgKGFj
dEVsKSBjYXJkLmluc2VydEJlZm9yZShzaG90LCBhY3RFbCk7CiAgICAgICAgICAg
ICAgICAgICAgICAgICAgICBlbHNlIHsKICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICBjb25zdCBtZXRhRWwgPSBjYXJkLnF1ZXJ5U2VsZWN0b3IoJy5pLW1l
dGEnKTsKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBpZiAobWV0YUVs
KSBjYXJkLmluc2VydEJlZm9yZShzaG90LCBtZXRhRWwpOwogICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgIGVsc2UgY2FyZC5hcHBlbmRDaGlsZChzaG90KTsK
ICAgICAgICAgICAgICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgICAg
ICAgICAgfTsKICAgICAgICAgICAgICAgICAgICAgICAgc2hvdEltZy5zcmMgPSBz
aG90VXJsKHVybCk7CiAgICAgICAgICAgICAgICAgICAgICAgIHNldFRpbWVvdXQo
KCkgPT4geyBpZiAoIXNldHRsZWQpIHJlamVjdCgpOyB9LCAxMjAwMCk7CiAgICAg
ICAgICAgICAgICAgICAgfSwgeyByb290OiBsaXN0RWwsIHJvb3RNYXJnaW46ICc0
MHB4JyB9KTsKICAgICAgICAgICAgICAgICAgICBsaW5rT2JzZXJ2ZXJzLnB1c2go
aW8pOwogICAgICAgICAgICAgICAgICAgIGlvLm9ic2VydmUoY2FyZCk7CiAgICAg
ICAgICAgICAgICB9KTsKICAgICAgICAgICAgfQoKICAgICAgICAgICAgY29uc3Qg
bWV0YSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAg
ICBtZXRhLmNsYXNzTmFtZSA9ICdpLW1ldGEnOwogICAgICAgICAgICBtZXRhLmlu
bmVySFRNTCA9CiAgICAgICAgICAgICAgICBgPHNwYW4gY2xhc3M9ImktdGltZSI+
JHthZ28oYy50aW1lKX08L3NwYW4+YCArCiAgICAgICAgICAgICAgICBtZXRhQ2Vu
dGVySHRtbCh7CiAgICAgICAgICAgICAgICAgICAgb246IGZhbHNlLAogICAgICAg
ICAgICAgICAgICAgIGh0bWw6IGA8c3ZnIHZpZXdCb3g9IjAgMCAxNiAxNiIgd2lk
dGg9IjEwIiBoZWlnaHQ9IjEwIiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRD
b2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCI+
PHBvbHlsaW5lIHBvaW50cz0iNCA2IDggMTAgMTIgNiIvPjwvc3ZnPuWxleW8gGAK
ICAgICAgICAgICAgICAgIH0pICsKICAgICAgICAgICAgICAgIGA8ZGl2IGNsYXNz
PSJpLW1ldGEtcmlnaHQiPiR7aG9zdCA/IGA8c3BhbiBjbGFzcz0iaS10YWciPiR7
aG9zdH08L3NwYW4+YCA6ICcnfTwvZGl2PmA7CiAgICAgICAgICAgIGNhcmQuYXBw
ZW5kQ2hpbGQobWV0YSk7CiAgICAgICAgICAgIGJvZHkuYXBwZW5kQ2hpbGQoY2Fy
ZCk7CgogICAgICAgICAgICBjb25zdCBleHBCdG4gPSBtZXRhLnF1ZXJ5U2VsZWN0
b3IoJy5pLWV4cGFuZC1idG4nKTsKICAgICAgICAgICAgaWYgKGV4cEJ0bikgewog
ICAgICAgICAgICAgICAgZXhwQnRuLm9uY2xpY2sgPSBlID0+IHsKICAgICAgICAg
ICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAg
ICAgIGNvbnN0IGV4cGFuZGVkID0gdXJsRWwuY2xhc3NMaXN0LnRvZ2dsZSgnZXhw
YW5kZWQnKTsKICAgICAgICAgICAgICAgICAgICBleHBCdG4uaW5uZXJIVE1MID0g
ZXhwYW5kZWQKICAgICAgICAgICAgICAgICAgICAgICAgPyBgPHN2ZyB2aWV3Qm94
PSIwIDAgMTYgMTYiIHdpZHRoPSIxMCIgaGVpZ2h0PSIxMCIgZmlsbD0ibm9uZSIg
c3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44IiBzdHJva2Ut
bGluZWNhcD0icm91bmQiPjxwb2x5bGluZSBwb2ludHM9IjQgMTAgOCA2IDEyIDEw
Ii8+PC9zdmc+5pS26LW3YAogICAgICAgICAgICAgICAgICAgICAgICA6IGA8c3Zn
IHZpZXdCb3g9IjAgMCAxNiAxNiIgd2lkdGg9IjEwIiBoZWlnaHQ9IjEwIiBmaWxs
PSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgi
IHN0cm9rZS1saW5lY2FwPSJyb3VuZCI+PHBvbHlsaW5lIHBvaW50cz0iNCA2IDgg
MTAgMTIgNiIvPjwvc3ZnPuWxleW8gGA7CiAgICAgICAgICAgICAgICB9OwogICAg
ICAgICAgICAgICAgY29uc3QgY2hlY2tPdmVyZmxvdyA9ICgpID0+IHsKICAgICAg
ICAgICAgICAgICAgICBpZiAodXJsRWwuc2Nyb2xsSGVpZ2h0ID4gdXJsRWwuY2xp
ZW50SGVpZ2h0ICsgMikKICAgICAgICAgICAgICAgICAgICAgICAgZXhwQnRuLmNs
YXNzTGlzdC5hZGQoJ29uJyk7CiAgICAgICAgICAgICAgICAgICAgZWxzZQogICAg
ICAgICAgICAgICAgICAgICAgICBleHBCdG4uY2xhc3NMaXN0LnJlbW92ZSgnb24n
KTsKICAgICAgICAgICAgICAgIH07CiAgICAgICAgICAgICAgICByZXF1ZXN0QW5p
bWF0aW9uRnJhbWUoY2hlY2tPdmVyZmxvdyk7CiAgICAgICAgICAgICAgICBzZXRU
aW1lb3V0KGNoZWNrT3ZlcmZsb3csIDgwKTsKICAgICAgICAgICAgfQogICAgICAg
IH0gZWxzZSB7CiAgICAgICAgICAgIGljby5jbGFzc05hbWUgPSAnaS1pY28gdGV4
dCc7CiAgICAgICAgICAgIGljby5pbm5lckhUTUwgPSBTVkcudGV4dDsKICAgICAg
ICAgICAgY29uc3QgdHh0ICA9IGMucHJldmlldyB8fCBjLmRhdGEgfHwgJyc7CiAg
ICAgICAgICAgIGNvbnN0IHByZXYgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdk
aXYnKTsKICAgICAgICAgICAgcHJldi5jbGFzc05hbWUgID0gJ2ktcHJldicgKyAo
aXNVcmwodHh0KSA/ICcgdXJsJyA6ICcnKTsKICAgICAgICAgICAgcHJldi50ZXh0
Q29udGVudCA9IHR4dDsKCiAgICAgICAgICAgIGNvbnN0IG1ldGEgPSBkb2N1bWVu
dC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgbWV0YS5jbGFzc05h
bWUgPSAnaS1tZXRhJzsKCiAgICAgICAgICAgIGNvbnN0IGlzTWQgPSBpc01hcmtk
b3duKGMuZGF0YSB8fCBjLnByZXZpZXcgfHwgJycpOwogICAgICAgICAgICBjb25z
dCBjaGFycyA9IE51bWJlcihjLmNoYXJDb3VudCkgfHwgMDsKICAgICAgICAgICAg
bGV0IHJpZ2h0SFRNTCA9ICcnOwogICAgICAgICAgICByaWdodEhUTUwgKz0gYDxz
cGFuIGNsYXNzPSJpLXRhZyBtZC1iYWRnZSR7aXNNZCA/ICcnIDogJyBvZmYnfSI+
TUQ8L3NwYW4+YDsKICAgICAgICAgICAgcmlnaHRIVE1MICs9IGA8c3BhbiBjbGFz
cz0iaS1jaGFycyI+PHNwYW4gY2xhc3M9Im4iPiR7Y2hhcnN9PC9zcGFuPiDlrZfn
rKY8L3NwYW4+YDsKCiAgICAgICAgICAgIG1ldGEuaW5uZXJIVE1MID0KICAgICAg
ICAgICAgICAgIGA8c3BhbiBjbGFzcz0iaS10aW1lIj4ke2FnbyhjLnRpbWUpfTwv
c3Bhbj5gICsKICAgICAgICAgICAgICAgIG1ldGFDZW50ZXJIdG1sKHsKICAgICAg
ICAgICAgICAgICAgICBvbjogZmFsc2UsCiAgICAgICAgICAgICAgICAgICAgaHRt
bDogYDxzdmcgdmlld0JveD0iMCAwIDE2IDE2IiB3aWR0aD0iMTAiIGhlaWdodD0i
MTAiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lk
dGg9IjEuOCIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIj48cG9seWxpbmUgcG9pbnRz
PSI0IDYgOCAxMCAxMiA2Ii8+PC9zdmc+5bGV5byAYAogICAgICAgICAgICAgICAg
fSkgKwogICAgICAgICAgICAgICAgYDxkaXYgY2xhc3M9ImktbWV0YS1yaWdodCB0
ZXh0LW1ldGEiPiR7cmlnaHRIVE1MfTwvZGl2PmA7CgogICAgICAgICAgICBib2R5
LmFwcGVuZENoaWxkKHByZXYpOwogICAgICAgICAgICBib2R5LmFwcGVuZENoaWxk
KG1ldGEpOwoKICAgICAgICAgICAgY29uc3QgZXhwQnRuID0gbWV0YS5xdWVyeVNl
bGVjdG9yKCcuaS1leHBhbmQtYnRuJyk7CiAgICAgICAgICAgIGlmIChleHBCdG4p
IHsKICAgICAgICAgICAgICAgIGV4cEJ0bi5vbmNsaWNrID0gZSA9PiB7CiAgICAg
ICAgICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAg
ICAgICAgICBjb25zdCBleHBhbmRlZCA9IHByZXYuY2xhc3NMaXN0LnRvZ2dsZSgn
ZXhwYW5kZWQnKTsKICAgICAgICAgICAgICAgICAgICBleHBCdG4uaW5uZXJIVE1M
ID0gZXhwYW5kZWQKICAgICAgICAgICAgICAgICAgICAgICAgPyBgPHN2ZyB2aWV3
Qm94PSIwIDAgMTYgMTYiIHdpZHRoPSIxMCIgaGVpZ2h0PSIxMCIgZmlsbD0ibm9u
ZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44IiBzdHJv
a2UtbGluZWNhcD0icm91bmQiPjxwb2x5bGluZSBwb2ludHM9IjQgMTAgOCA2IDEy
IDEwIi8+PC9zdmc+5pS26LW3YAogICAgICAgICAgICAgICAgICAgICAgICA6IGA8
c3ZnIHZpZXdCb3g9IjAgMCAxNiAxNiIgd2lkdGg9IjEwIiBoZWlnaHQ9IjEwIiBm
aWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIx
LjgiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCI+PHBvbHlsaW5lIHBvaW50cz0iNCA2
IDggMTAgMTIgNiIvPjwvc3ZnPuWxleW8gGA7CiAgICAgICAgICAgICAgICB9Owog
ICAgICAgICAgICAgICAgY29uc3QgY2hlY2tPdmVyZmxvdyA9ICgpID0+IHsKICAg
ICAgICAgICAgICAgICAgICBpZiAocHJldi5zY3JvbGxIZWlnaHQgPiBwcmV2LmNs
aWVudEhlaWdodCArIDIpCiAgICAgICAgICAgICAgICAgICAgICAgIGV4cEJ0bi5j
bGFzc0xpc3QuYWRkKCdvbicpOwogICAgICAgICAgICAgICAgICAgIGVsc2UKICAg
ICAgICAgICAgICAgICAgICAgICAgZXhwQnRuLmNsYXNzTGlzdC5yZW1vdmUoJ29u
Jyk7CiAgICAgICAgICAgICAgICB9OwogICAgICAgICAgICAgICAgcmVxdWVzdEFu
aW1hdGlvbkZyYW1lKGNoZWNrT3ZlcmZsb3cpOwogICAgICAgICAgICAgICAgc2V0
VGltZW91dChjaGVja092ZXJmbG93LCA4MCk7CiAgICAgICAgICAgIH0KICAgICAg
ICB9CgogICAgICAgIGNvbnN0IGZhdlQgPSBTdHJpbmcoYy5mYXZUaXRsZSB8fCAn
JykudHJpbSgpOwogICAgICAgIGlmIChmYXZUKSB7CiAgICAgICAgICAgIGNvbnN0
IGZ0ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAg
IGZ0LmNsYXNzTmFtZSA9ICdpLWZhdi10aXRsZSc7CiAgICAgICAgICAgIGZ0LnRl
eHRDb250ZW50ID0gZmF2VDsKICAgICAgICAgICAgYm9keS5pbnNlcnRCZWZvcmUo
ZnQsIGJvZHkuZmlyc3RDaGlsZCk7CiAgICAgICAgfQoKICAgICAgICBpZiAocGFz
dGVkKSB7CiAgICAgICAgICAgIGNvbnN0IGJhZGdlID0gZG9jdW1lbnQuY3JlYXRl
RWxlbWVudCgnc3BhbicpOwogICAgICAgICAgICBiYWRnZS5jbGFzc05hbWUgPSAn
aS11c2VkJzsKICAgICAgICAgICAgYmFkZ2UudGl0bGUgPSAn5bey57KY6LS0JzsK
ICAgICAgICAgICAgYmFkZ2UuaW5uZXJIVE1MID0gYDxzdmcgdmlld0JveD0iMCAw
IDE2IDE2IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tl
LXdpZHRoPSIyLjQiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVq
b2luPSJyb3VuZCI+PHBvbHlsaW5lIHBvaW50cz0iMy41IDguNSA2LjUgMTEuNSAx
Mi41IDQuNSIvPjwvc3ZnPmA7CiAgICAgICAgICAgIGljby5hcHBlbmRDaGlsZChi
YWRnZSk7CiAgICAgICAgfQoKICAgICAgICBjb25zdCBudW0gPSBkb2N1bWVudC5j
cmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICBudW0uY2xhc3NOYW1lID0gJ2kt
bnVtJzsKICAgICAgICBjb25zdCBudW1UeHQgPSBkb2N1bWVudC5jcmVhdGVFbGVt
ZW50KCdzcGFuJyk7CiAgICAgICAgbnVtVHh0LnRleHRDb250ZW50ID0gaWR4Owog
ICAgICAgIG51bS5hcHBlbmRDaGlsZChudW1UeHQpOwogICAgICAgIGNvbnN0IHNy
Y0ljbyA9IFN0cmluZyhjLnNyY0ljb24gfHwgJycpOwogICAgICAgIGNvbnN0IHNy
Y0V4ZSA9IFN0cmluZyhjLnNyY0V4ZSB8fCAnJyk7CiAgICAgICAgaWYgKHNyY0lj
bykgewogICAgICAgICAgICBjb25zdCBpbWcgPSBkb2N1bWVudC5jcmVhdGVFbGVt
ZW50KCdpbWcnKTsKICAgICAgICAgICAgaW1nLmNsYXNzTmFtZSA9ICdpLXNyYy1p
Y28nOwogICAgICAgICAgICBpbWcuc3JjID0gU1RPUkVfQkFTRSArIGVuY29kZVVS
SUNvbXBvbmVudChzcmNJY28pOwogICAgICAgICAgICBpbWcuYWx0ID0gJyc7CiAg
ICAgICAgICAgIGltZy50aXRsZSA9IHNyY0V4ZSB8fCAn5p2l5rqQJzsKICAgICAg
ICAgICAgbnVtLmFwcGVuZENoaWxkKGltZyk7CiAgICAgICAgfQoKICAgICAgICBl
bC5hcHBlbmRDaGlsZChpY28pOwogICAgICAgIGVsLmFwcGVuZENoaWxkKGJvZHkp
OwogICAgICAgIGVsLmFwcGVuZENoaWxkKG51bSk7CgogICAgICAgIGVsLm9uY2xp
Y2sgPSBlID0+IHsKICAgICAgICAgICAgaWYgKGUuY3RybEtleSB8fCBlLm1ldGFL
ZXkpIHsKICAgICAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAg
ICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgICAgICB0
b2dnbGVNdWx0aShjLmlkKTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAg
ICAgICAgfQogICAgICAgICAgICBzZWxlY3RlZElkID0gYy5pZDsKICAgICAgICAg
ICAgaWYgKG11bHRpSWRzLmxlbmd0aCA+IDAgJiYgbXVsdGlJZHMuaW5jbHVkZXMo
K2MuaWQpKSB7CiAgICAgICAgICAgICAgICBjb25zdCBpZHMgPSBtdWx0aUlkcy5z
bGljZSgpOwogICAgICAgICAgICAgICAgY2xlYXJNdWx0aSgpOwogICAgICAgICAg
ICAgICAgbWFya1Bhc3RlZExvY2FsKGlkcyk7CiAgICAgICAgICAgICAgICBpZiAo
aWRzLmxlbmd0aCA+IDEpIGFoaygncGFzdGVNYW55JywgaWRzLmpvaW4oJywnKSk7
CiAgICAgICAgICAgICAgICBlbHNlIGFoaygncGFzdGUnLCBTdHJpbmcoaWRzWzBd
KSk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAg
ICAgICAgaWYgKG11bHRpSWRzLmxlbmd0aCkgY2xlYXJNdWx0aSgpOwogICAgICAg
ICAgICBzeW5jSXRlbUhpZ2hsaWdodCgpOwogICAgICAgICAgICBtYXJrUGFzdGVk
TG9jYWwoYy5pZCk7CiAgICAgICAgICAgIGFoaygncGFzdGUnLCBTdHJpbmcoYy5p
ZCkpOwogICAgICAgIH07CiAgICAgICAgZWwub25jb250ZXh0bWVudSA9IGUgPT4g
ewogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgIHNl
bGVjdGVkSWQgPSBjLmlkOwogICAgICAgICAgICBzaG93Q3R4KGUuY2xpZW50WCwg
ZS5jbGllbnRZLCBjKTsKICAgICAgICB9OwoKICAgICAgICByZXR1cm4gZWw7CiAg
ICB9CgogICAgY29uc3QgcGF0aFRpcEVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ3BhdGgtdGlwJyk7CiAgICBsZXQgcGF0aFRpcFRpbWVyID0gMDsKICAgIGxl
dCBwYXRoVGlwSGlkZVRpbWVyID0gMDsKICAgIGxldCBwYXRoVGlwVG9rZW4gPSAw
OwogICAgbGV0IHBhdGhUaXBBbmNob3JCdG4gPSBudWxsOwoKICAgIGZ1bmN0aW9u
IGhpZGVQYXRoVGlwKCkgewogICAgICAgIGNsZWFyVGltZW91dChwYXRoVGlwVGlt
ZXIpOwogICAgICAgIGNsZWFyVGltZW91dChwYXRoVGlwSGlkZVRpbWVyKTsKICAg
ICAgICBwYXRoVGlwVG9rZW4rKzsKICAgICAgICBpZiAocGF0aFRpcEFuY2hvckJ0
bikgewogICAgICAgICAgICBwYXRoVGlwQW5jaG9yQnRuLmNsYXNzTGlzdC5yZW1v
dmUoJ29uJyk7CiAgICAgICAgICAgIHBhdGhUaXBBbmNob3JCdG4gPSBudWxsOwog
ICAgICAgIH0KICAgICAgICBpZiAocGF0aFRpcEVsKSB7CiAgICAgICAgICAgIHBh
dGhUaXBFbC5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgICAgICBwYXRo
VGlwRWwuc2V0QXR0cmlidXRlKCdhcmlhLWhpZGRlbicsICd0cnVlJyk7CiAgICAg
ICAgfQogICAgfQogICAgZnVuY3Rpb24gcGxhY2VQYXRoVGlwKGFuY2hvckVsKSB7
CiAgICAgICAgaWYgKCFwYXRoVGlwRWwgfHwgIWFuY2hvckVsKSByZXR1cm47CiAg
ICAgICAgY29uc3QgdGlwID0gcGF0aFRpcEVsOwogICAgICAgIGNvbnN0IGFyID0g
YW5jaG9yRWwuZ2V0Qm91bmRpbmdDbGllbnRSZWN0KCk7CiAgICAgICAgY29uc3Qg
cGFkID0gODsKICAgICAgICB0aXAuc3R5bGUubGVmdCA9ICcwcHgnOwogICAgICAg
IHRpcC5zdHlsZS50b3AgPSAnMHB4JzsKICAgICAgICB0aXAuY2xhc3NMaXN0LmFk
ZCgnb24nKTsKICAgICAgICBjb25zdCB0dyA9IHRpcC5vZmZzZXRXaWR0aDsKICAg
ICAgICBjb25zdCB0aCA9IHRpcC5vZmZzZXRIZWlnaHQ7CiAgICAgICAgbGV0IGxl
ZnQgPSBhci5sZWZ0OwogICAgICAgIGxldCB0b3AgPSBhci5ib3R0b20gKyA2Owog
ICAgICAgIGlmIChsZWZ0ICsgdHcgPiB3aW5kb3cuaW5uZXJXaWR0aCAtIHBhZCkK
ICAgICAgICAgICAgbGVmdCA9IE1hdGgubWF4KHBhZCwgd2luZG93LmlubmVyV2lk
dGggLSB0dyAtIHBhZCk7CiAgICAgICAgaWYgKGxlZnQgPCBwYWQpIGxlZnQgPSBw
YWQ7CiAgICAgICAgaWYgKHRvcCArIHRoID4gd2luZG93LmlubmVySGVpZ2h0IC0g
cGFkKQogICAgICAgICAgICB0b3AgPSBNYXRoLm1heChwYWQsIGFyLnRvcCAtIHRo
IC0gNik7CiAgICAgICAgdGlwLnN0eWxlLmxlZnQgPSBsZWZ0ICsgJ3B4JzsKICAg
ICAgICB0aXAuc3R5bGUudG9wID0gdG9wICsgJ3B4JzsKICAgIH0KICAgIGZ1bmN0
aW9uIGNoZWNrRmlsZVBhdGhzKHBhdGhzKSB7CiAgICAgICAgcmV0dXJuIChwYXRo
cyB8fCBbXSkubWFwKHAgPT4gewogICAgICAgICAgICBsZXQgcGF0aCA9IFN0cmlu
ZyhwIHx8ICcnKS50cmltKCk7CiAgICAgICAgICAgIC8vIFN0cmlwIHdyYXBwaW5n
IHF1b3RlcyBmcm9tIEV4cGxvcmVyLXN0eWxlIHBhdGhzCiAgICAgICAgICAgIGlm
ICgocGF0aC5zdGFydHNXaXRoKCciJykgJiYgcGF0aC5lbmRzV2l0aCgnIicpKSB8
fCAocGF0aC5zdGFydHNXaXRoKCInIikgJiYgcGF0aC5lbmRzV2l0aCgiJyIpKSkK
ICAgICAgICAgICAgICAgIHBhdGggPSBwYXRoLnNsaWNlKDEsIC0xKS50cmltKCk7
CiAgICAgICAgICAgIGxldCBleGlzdHMgPSBudWxsOwogICAgICAgICAgICBpZiAo
IXBhdGgpIHJldHVybiB7IHBhdGgsIGV4aXN0czogZmFsc2UsIGlzRGlyOiBmYWxz
ZSB9OwogICAgICAgICAgICB0cnkgewogICAgICAgICAgICAgICAgLy8gUHJlZmVy
IHNpbXBsZSAiMSIvIjAiIOKAlCBtb3JlIHJlbGlhYmxlIHRocm91Z2ggV2ViVmll
dyBob3N0T2JqZWN0cwogICAgICAgICAgICAgICAgY29uc3QgZmxhZyA9IFN0cmlu
ZyhhaGtSZXQoJ3BhdGhFeGlzdHMnLCBwYXRoKSA/PyAnJykudHJpbSgpLnRvTG93
ZXJDYXNlKCk7CiAgICAgICAgICAgICAgICBpZiAoZmxhZyA9PT0gJzEnIHx8IGZs
YWcgPT09ICd0cnVlJykgZXhpc3RzID0gdHJ1ZTsKICAgICAgICAgICAgICAgIGVs
c2UgaWYgKGZsYWcgPT09ICcwJyB8fCBmbGFnID09PSAnZmFsc2UnKSBleGlzdHMg
PSBmYWxzZTsKICAgICAgICAgICAgfSBjYXRjaCB7fQogICAgICAgICAgICBpZiAo
ZXhpc3RzID09PSBudWxsKSB7CiAgICAgICAgICAgICAgICB0cnkgewogICAgICAg
ICAgICAgICAgICAgIGNvbnN0IHJldCA9IGFoa1JldCgnY2hlY2tQYXRocycsIHBh
dGgpOwogICAgICAgICAgICAgICAgICAgIGNvbnN0IHRleHQgPSByZXQgPT0gbnVs
bCA/ICcnIDogU3RyaW5nKHJldCk7CiAgICAgICAgICAgICAgICAgICAgY29uc3Qg
cGFyc2VkID0gdGV4dCA/IEpTT04ucGFyc2UodGV4dCkgOiBudWxsOwogICAgICAg
ICAgICAgICAgICAgIGlmIChBcnJheS5pc0FycmF5KHBhcnNlZCkgJiYgcGFyc2Vk
WzBdKSB7CiAgICAgICAgICAgICAgICAgICAgICAgIGNvbnN0IHggPSBwYXJzZWRb
MF07CiAgICAgICAgICAgICAgICAgICAgICAgIGlmICh4LmV4aXN0cyA9PT0gdHJ1
ZSB8fCB4LmV4aXN0cyA9PT0gMSB8fCB4LmV4aXN0cyA9PT0gJ3RydWUnKQogICAg
ICAgICAgICAgICAgICAgICAgICAgICAgZXhpc3RzID0gdHJ1ZTsKICAgICAgICAg
ICAgICAgICAgICAgICAgZWxzZSBpZiAoeC5leGlzdHMgPT09IGZhbHNlIHx8IHgu
ZXhpc3RzID09PSAwIHx8IHguZXhpc3RzID09PSAnZmFsc2UnKQogICAgICAgICAg
ICAgICAgICAgICAgICAgICAgZXhpc3RzID0gZmFsc2U7CiAgICAgICAgICAgICAg
ICAgICAgfQogICAgICAgICAgICAgICAgfSBjYXRjaCB7fQogICAgICAgICAgICB9
CiAgICAgICAgICAgIHJldHVybiB7IHBhdGgsIGV4aXN0cywgaXNEaXI6IGZhbHNl
IH07CiAgICAgICAgfSk7CiAgICB9CiAgICBmdW5jdGlvbiBmaWxsRmlsZURldGFp
bFBhbmVsKGNvbnRhaW5lciwgcm93cykgewogICAgICAgIGNvbnRhaW5lci5pbm5l
ckhUTUwgPSAnJzsKICAgICAgICBpZiAoIXJvd3MubGVuZ3RoKSB7CiAgICAgICAg
ICAgIGNvbnN0IGVtcHR5ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7
CiAgICAgICAgICAgIGVtcHR5LmNsYXNzTmFtZSA9ICdmZC1wYXRoJzsKICAgICAg
ICAgICAgZW1wdHkudGV4dENvbnRlbnQgPSAn5peg6Lev5b6EJzsKICAgICAgICAg
ICAgY29udGFpbmVyLmFwcGVuZENoaWxkKGVtcHR5KTsKICAgICAgICAgICAgcmV0
dXJuOwogICAgICAgIH0KICAgICAgICByb3dzLmZvckVhY2gociA9PiB7CiAgICAg
ICAgICAgIGNvbnN0IHBhdGggPSBTdHJpbmcoci5wYXRoIHx8ICcnKTsKICAgICAg
ICAgICAgY29uc3QgbWlzc2luZyA9IHIuZXhpc3RzID09PSBmYWxzZTsKICAgICAg
ICAgICAgY29uc3QgYmxvY2sgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYn
KTsKICAgICAgICAgICAgYmxvY2suY2xhc3NOYW1lID0gJ2ZkLWJsb2NrJzsKCiAg
ICAgICAgICAgIGNvbnN0IHBhdGhFbCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQo
J2RpdicpOwogICAgICAgICAgICBwYXRoRWwuY2xhc3NOYW1lID0gJ2ZkLXBhdGgn
ICsgKG1pc3NpbmcgPyAnIGRlYWQnIDogJyBsaXZlJyk7CiAgICAgICAgICAgIHBh
dGhFbC50ZXh0Q29udGVudCA9IHBhdGggfHwgJyjnqbrot6/lvoQpJzsKICAgICAg
ICAgICAgaWYgKCFtaXNzaW5nKSB7CiAgICAgICAgICAgICAgICBwYXRoRWwub25j
bGljayA9IGUgPT4gewogICAgICAgICAgICAgICAgICAgIGUucHJldmVudERlZmF1
bHQoKTsKICAgICAgICAgICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwog
ICAgICAgICAgICAgICAgICAgIGFoaygnb3BlblBhdGgnLCBwYXRoKTsKICAgICAg
ICAgICAgICAgIH07CiAgICAgICAgICAgIH0KICAgICAgICAgICAgYmxvY2suYXBw
ZW5kQ2hpbGQocGF0aEVsKTsKCiAgICAgICAgICAgIGNvbnN0IGFjdGlvbnMgPSBk
b2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgYWN0aW9u
cy5jbGFzc05hbWUgPSAnZmQtYWN0aW9ucyc7CgogICAgICAgICAgICBjb25zdCBj
b3B5QnRuID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnYnV0dG9uJyk7CiAgICAg
ICAgICAgIGNvcHlCdG4udHlwZSA9ICdidXR0b24nOwogICAgICAgICAgICBjb3B5
QnRuLmNsYXNzTmFtZSA9ICdmZC1idG4nOwogICAgICAgICAgICBjb3B5QnRuLmlu
bmVySFRNTCA9ICc8c3BhbiBjbGFzcz0iZmQtaWNvIj7wn5SXPC9zcGFuPjxzcGFu
IGNsYXNzPSJmZC10eHQiPuWkjeWItui3r+W+hDwvc3Bhbj4nOwogICAgICAgICAg
ICBjb3B5QnRuLm9uY2xpY2sgPSBlID0+IHsKICAgICAgICAgICAgICAgIGUucHJl
dmVudERlZmF1bHQoKTsKICAgICAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9u
KCk7CiAgICAgICAgICAgICAgICBhaGsoJ2NvcHlQYXRoJywgcGF0aCk7CiAgICAg
ICAgICAgICAgICBjb3B5QnRuLnF1ZXJ5U2VsZWN0b3IoJy5mZC10eHQnKS50ZXh0
Q29udGVudCA9ICflt7LlpI3liLYnOwogICAgICAgICAgICAgICAgY29weUJ0bi5j
bGFzc0xpc3QuYWRkKCdvaycpOwogICAgICAgICAgICAgICAgc2V0VGltZW91dCgo
KSA9PiB7CiAgICAgICAgICAgICAgICAgICAgY29weUJ0bi5xdWVyeVNlbGVjdG9y
KCcuZmQtdHh0JykudGV4dENvbnRlbnQgPSAn5aSN5Yi26Lev5b6EJzsKICAgICAg
ICAgICAgICAgICAgICBjb3B5QnRuLmNsYXNzTGlzdC5yZW1vdmUoJ29rJyk7CiAg
ICAgICAgICAgICAgICB9LCAxMjAwKTsKICAgICAgICAgICAgfTsKICAgICAgICAg
ICAgYWN0aW9ucy5hcHBlbmRDaGlsZChjb3B5QnRuKTsKCiAgICAgICAgICAgIGNv
bnN0IGZvbGRlckJ0biA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2J1dHRvbicp
OwogICAgICAgICAgICBmb2xkZXJCdG4udHlwZSA9ICdidXR0b24nOwogICAgICAg
ICAgICBmb2xkZXJCdG4uY2xhc3NOYW1lID0gJ2ZkLWJ0bic7CiAgICAgICAgICAg
IGZvbGRlckJ0bi5pbm5lckhUTUwgPSAnPHNwYW4gY2xhc3M9ImZkLWljbyI+8J+T
gjwvc3Bhbj48c3BhbiBjbGFzcz0iZmQtdHh0Ij7miZPlvIDmiYDlnKjmlofku7bl
pLk8L3NwYW4+JzsKICAgICAgICAgICAgZm9sZGVyQnRuLm9uY2xpY2sgPSBlID0+
IHsKICAgICAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAg
ICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgICAgICBhaGso
J29wZW5Gb2xkZXInLCBwYXRoKTsKICAgICAgICAgICAgfTsKICAgICAgICAgICAg
YWN0aW9ucy5hcHBlbmRDaGlsZChmb2xkZXJCdG4pOwoKICAgICAgICAgICAgYmxv
Y2suYXBwZW5kQ2hpbGQoYWN0aW9ucyk7CiAgICAgICAgICAgIGNvbnRhaW5lci5h
cHBlbmRDaGlsZChibG9jayk7CiAgICAgICAgfSk7CiAgICB9CgogICAgY29uc3Qg
Y3R4RWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY3R4Jyk7CiAgICBmdW5j
dGlvbiBzaG93Q3R4KHgsIHksIGMpIHsKICAgICAgICBjdHhDbGlwID0gYzsKICAg
ICAgICBjb25zdCBjbGVhckJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdj
LWNsZWFyLXBhc3RlZCcpOwogICAgICAgIGlmIChjbGVhckJ0bikgY2xlYXJCdG4u
c3R5bGUuZGlzcGxheSA9IGlzUGFzdGVkKGMpID8gJycgOiAnbm9uZSc7CgogICAg
ICAgIGNvbnN0IHBpbkJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjLXBp
bicpOwogICAgICAgIGlmIChwaW5CdG4pIHsKICAgICAgICAgICAgY29uc3Qgb24g
PSBpc1Bpbm5lZChjKTsKICAgICAgICAgICAgcGluQnRuLmlubmVySFRNTCA9IG9u
CiAgICAgICAgICAgICAgICA/ICc8c3BhbiBjbGFzcz0iYy1pY28iPuKYhTwvc3Bh
bj7lj5bmtojmlLbol48nCiAgICAgICAgICAgICAgICA6ICc8c3BhbiBjbGFzcz0i
Yy1pY28iPuKYhTwvc3Bhbj7mlLbol48nOwogICAgICAgIH0KICAgICAgICBjb25z
dCB0aXRsZUJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjLXRpdGxlJyk7
CiAgICAgICAgaWYgKHRpdGxlQnRuKSB7CiAgICAgICAgICAgIGNvbnN0IHNob3dU
aXRsZSA9IGlzUGlubmVkKGMpIHx8IGN1clRhYiA9PT0gJ3Bpbm5lZCc7CiAgICAg
ICAgICAgIHRpdGxlQnRuLnN0eWxlLmRpc3BsYXkgPSBzaG93VGl0bGUgPyAnJyA6
ICdub25lJzsKICAgICAgICAgICAgaWYgKHNob3dUaXRsZSkKICAgICAgICAgICAg
ICAgIHRpdGxlQnRuLmlubmVySFRNTCA9IChTdHJpbmcoYy5mYXZUaXRsZSB8fCAn
JykudHJpbSgpID8gJzxzcGFuIGNsYXNzPSJjLWljbyI+4pyOPC9zcGFuPue8lui+
keagh+mimCcgOiAnPHNwYW4gY2xhc3M9ImMtaWNvIj7inI48L3NwYW4+6K6+572u
5qCH6aKYJyk7CiAgICAgICAgfQogICAgICAgIGNvbnN0IG1lcmdlQnRuID0gZG9j
dW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtbWVyZ2UnKTsKICAgICAgICBjb25zdCB1
bm1lcmdlQnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2MtdW5tZXJnZScp
OwogICAgICAgIGNvbnN0IG9uUGlubmVkID0gY3VyVGFiID09PSAncGlubmVkJzsK
ICAgICAgICBpZiAobWVyZ2VCdG4pCiAgICAgICAgICAgIG1lcmdlQnRuLnN0eWxl
LmRpc3BsYXkgPSAob25QaW5uZWQgJiYgbXVsdGlJZHMubGVuZ3RoID49IDIpID8g
JycgOiAnbm9uZSc7CiAgICAgICAgaWYgKHVubWVyZ2VCdG4pCiAgICAgICAgICAg
IHVubWVyZ2VCdG4uc3R5bGUuZGlzcGxheSA9IChvblBpbm5lZCAmJiBmYXZHcm91
cE9mKGMpKSA/ICcnIDogJ25vbmUnOwogICAgICAgIGN0eEVsLmNsYXNzTGlzdC5h
ZGQoJ29uJyk7CiAgICAgICAgY3R4RWwuc3R5bGUubGVmdCA9IHggKyAncHgnOwog
ICAgICAgIGN0eEVsLnN0eWxlLnRvcCAgPSB5ICsgJ3B4JzsKICAgICAgICByZXF1
ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4gewogICAgICAgICAgICBjb25zdCByID0g
Y3R4RWwuZ2V0Qm91bmRpbmdDbGllbnRSZWN0KCk7CiAgICAgICAgICAgIGlmIChy
LnJpZ2h0ICA+IGlubmVyV2lkdGgpICBjdHhFbC5zdHlsZS5sZWZ0ID0gKHggLSBy
LndpZHRoKSAgKyAncHgnOwogICAgICAgICAgICBpZiAoci5ib3R0b20gPiBpbm5l
ckhlaWdodCkgY3R4RWwuc3R5bGUudG9wICA9ICh5IC0gci5oZWlnaHQpICsgJ3B4
JzsKICAgICAgICB9KTsKICAgIH0KICAgIGZ1bmN0aW9uIGhpZGVDdHgoKSB7IGN0
eEVsLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7IGN0eENsaXAgPSBudWxsOyB9CiAg
ICB3aW5kb3cuX19oaWRlQ3R4ID0gaGlkZUN0eDsKCiAgICBkb2N1bWVudC5hZGRF
dmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4geyBpZiAoIWUudGFyZ2V0LmNsb3Nl
c3QoJyNjdHgnKSkgaGlkZUN0eCgpOyB9KTsKICAgIGRvY3VtZW50LmFkZEV2ZW50
TGlzdGVuZXIoJ2tleWRvd24nLCBlID0+IHsKICAgICAgICAvLyBFc2M6IGFsd2F5
cyBjbG9zZSBwYW5lbCAoc2VhcmNoIG9yIG5vdCk7IHBpbiBrZWVwcyBwYW5lbAog
ICAgICAgIGlmIChlLmtleSA9PT0gJ0VzY2FwZScpIHsKICAgICAgICAgICAgZS5w
cmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICBoaWRlQ3R4KCk7CiAgICAgICAg
ICAgIGNvbnN0IHRkID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RpdGxlLWRs
ZycpOwogICAgICAgICAgICBpZiAodGQgJiYgdGQuY2xhc3NMaXN0LmNvbnRhaW5z
KCdvbicpKSB7CiAgICAgICAgICAgICAgICB0cnkgeyBjbG9zZVRpdGxlRGxnKCk7
IH0gY2F0Y2ggeyB0ZC5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOyB9CiAgICAgICAg
ICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKGNs
ckRsZy5jbGFzc0xpc3QuY29udGFpbnMoJ29uJykpIHsKICAgICAgICAgICAgICAg
IGNsb3NlQ2xlYXJEbGcoKTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAg
ICAgICAgfQogICAgICAgICAgICBpZiAoIXBpbm5lZFVJKSBhaGsoJ2hpZGUnKTsK
ICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICAvLyBXaGlsZSB0
eXBpbmcgaW4gc2VhcmNoOiBDdHJsK0kvSyBhbmQgYXJyb3dzIG1vdmUgbGlzdCwg
ZG9uJ3QgbGVhdmUgdGhlIGJveAogICAgICAgIGlmIChkb2N1bWVudC5hY3RpdmVF
bGVtZW50Py5pZCA9PT0gJ3NlYXJjaCcpIHsKICAgICAgICAgICAgaWYgKChlLmN0
cmxLZXkgfHwgZS5tZXRhS2V5KSAmJiAoZS5rZXkgPT09ICdpJyB8fCBlLmtleSA9
PT0gJ0knKSkgewogICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOyBl
LnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAgd2luZG93Ll9fbmF2
ICYmIHdpbmRvdy5fX25hdigndXAnKTsKICAgICAgICAgICAgICAgIHJldHVybjsK
ICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAoKGUuY3RybEtleSB8fCBlLm1l
dGFLZXkpICYmIChlLmtleSA9PT0gJ2snIHx8IGUua2V5ID09PSAnSycpKSB7CiAg
ICAgICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0
aW9uKCk7CiAgICAgICAgICAgICAgICB3aW5kb3cuX19uYXYgJiYgd2luZG93Ll9f
bmF2KCdkb3duJyk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAg
IH0KICAgICAgICAgICAgaWYgKGUua2V5ID09PSAnQXJyb3dEb3duJykgewogICAg
ICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOyBlLnN0b3BQcm9wYWdhdGlv
bigpOwogICAgICAgICAgICAgICAgd2luZG93Ll9fbmF2ICYmIHdpbmRvdy5fX25h
dignZG93bicpOwogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICB9
CiAgICAgICAgICAgIGlmIChlLmtleSA9PT0gJ0Fycm93VXAnKSB7CiAgICAgICAg
ICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0aW9uKCk7
CiAgICAgICAgICAgICAgICB3aW5kb3cuX19uYXYgJiYgd2luZG93Ll9fbmF2KCd1
cCcpOwogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICB9CiAgICAg
ICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgY29uc3QgdmlzID0gdmlz
aWJsZUxpc3QoKTsKICAgICAgICBpZiAoIXZpcy5sZW5ndGgpIHJldHVybjsKICAg
ICAgICBsZXQgaWR4ID0gc2VsZWN0ZWRJbmRleCgpOwogICAgICAgIGlmIChpZHgg
PCAwKSBpZHggPSAwOwogICAgICAgIGlmICAgICAgKGUua2V5ID09PSAnQXJyb3dE
b3duJykgeyBlLnByZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0aW9uKCk7
IHNlbGVjdEJ5SW5kZXgoaWR4ICsgMSk7IH0KICAgICAgICBlbHNlIGlmIChlLmtl
eSA9PT0gJ0Fycm93VXAnKSAgIHsgZS5wcmV2ZW50RGVmYXVsdCgpOyBlLnN0b3BQ
cm9wYWdhdGlvbigpOyBzZWxlY3RCeUluZGV4KGlkeCAtIDEpOyB9CiAgICAgICAg
ZWxzZSBpZiAoZS5rZXkgPT09ICdFbnRlcicpIHsKICAgICAgICAgICAgZS5wcmV2
ZW50RGVmYXVsdCgpOwogICAgICAgICAgICBpZiAobXVsdGlJZHMubGVuZ3RoID4g
MSkgewogICAgICAgICAgICAgICAgY29uc3QgaWRzID0gbXVsdGlJZHMuc2xpY2Uo
KTsKICAgICAgICAgICAgICAgIGNsZWFyTXVsdGkoKTsKICAgICAgICAgICAgICAg
IG1hcmtQYXN0ZWRMb2NhbChpZHMpOwogICAgICAgICAgICAgICAgYWhrKCdwYXN0
ZU1hbnknLCBpZHMuam9pbignLCcpKTsKICAgICAgICAgICAgICAgIHJldHVybjsK
ICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAobXVsdGlJZHMubGVuZ3RoID09
PSAxKSB7CiAgICAgICAgICAgICAgICBjb25zdCBpZCA9IG11bHRpSWRzWzBdOwog
ICAgICAgICAgICAgICAgY2xlYXJNdWx0aSgpOwogICAgICAgICAgICAgICAgbWFy
a1Bhc3RlZExvY2FsKGlkKTsKICAgICAgICAgICAgICAgIGFoaygncGFzdGUnLCBT
dHJpbmcoaWQpKTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAg
fQogICAgICAgICAgICBjb25zdCBjID0gdmlzW3NlbGVjdGVkSW5kZXgoKV07CiAg
ICAgICAgICAgIGlmIChjKSB7CiAgICAgICAgICAgICAgICBtYXJrUGFzdGVkTG9j
YWwoYy5pZCk7CiAgICAgICAgICAgICAgICBhaGsoJ3Bhc3RlJywgU3RyaW5nKGMu
aWQpKTsKICAgICAgICAgICAgfQogICAgICAgIH0gZWxzZSBpZiAoL15bMS05XSQv
LnRlc3QoZS5rZXkpKSB7CiAgICAgICAgICAgIGNvbnN0IGMgPSB2aXNbK2Uua2V5
IC0gMV07CiAgICAgICAgICAgIGlmIChjKSB7CiAgICAgICAgICAgICAgICBtYXJr
UGFzdGVkTG9jYWwoYy5pZCk7CiAgICAgICAgICAgICAgICBhaGsoJ3Bhc3RlJywg
U3RyaW5nKGMuaWQpKTsKICAgICAgICAgICAgfQogICAgICAgIH0KICAgIH0pOwoK
ICAgIHdpbmRvdy5fX25hdiA9IGRpciA9PiB7CiAgICAgICAgY29uc3QgdmlzID0g
dmlzaWJsZUxpc3QoKTsKICAgICAgICBpZiAoIXZpcy5sZW5ndGggJiYgZGlyICE9
PSAndGFiJyAmJiBkaXIgIT09ICd0YWJQcmV2JykgcmV0dXJuOwogICAgICAgIGxl
dCBpZHggPSBzZWxlY3RlZEluZGV4KCk7CiAgICAgICAgaWYgKGlkeCA8IDApIGlk
eCA9IDA7CiAgICAgICAgaWYgKGRpciA9PT0gJ3VwJykgc2VsZWN0QnlJbmRleChp
ZHggLSAxKTsKICAgICAgICBlbHNlIGlmIChkaXIgPT09ICdkb3duJykgc2VsZWN0
QnlJbmRleChpZHggKyAxKTsKICAgICAgICBlbHNlIGlmIChkaXIgPT09ICdlbnRl
cicpIHsKICAgICAgICAgICAgaWYgKG11bHRpSWRzLmxlbmd0aCA+IDEpIHsKICAg
ICAgICAgICAgICAgIGNvbnN0IGlkcyA9IG11bHRpSWRzLnNsaWNlKCk7CiAgICAg
ICAgICAgICAgICBjbGVhck11bHRpKCk7CiAgICAgICAgICAgICAgICBtYXJrUGFz
dGVkTG9jYWwoaWRzKTsKICAgICAgICAgICAgICAgIGFoaygncGFzdGVNYW55Jywg
aWRzLmpvaW4oJywnKSk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAg
ICAgIH0KICAgICAgICAgICAgaWYgKG11bHRpSWRzLmxlbmd0aCA9PT0gMSkgewog
ICAgICAgICAgICAgICAgY29uc3QgaWQgPSBtdWx0aUlkc1swXTsKICAgICAgICAg
ICAgICAgIGNsZWFyTXVsdGkoKTsKICAgICAgICAgICAgICAgIG1hcmtQYXN0ZWRM
b2NhbChpZCk7CiAgICAgICAgICAgICAgICBhaGsoJ3Bhc3RlJywgU3RyaW5nKGlk
KSk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAg
ICAgICAgY29uc3QgYyA9IHZpc1tzZWxlY3RlZEluZGV4KCldOwogICAgICAgICAg
ICBpZiAoYykgewogICAgICAgICAgICAgICAgbWFya1Bhc3RlZExvY2FsKGMuaWQp
OwogICAgICAgICAgICAgICAgYWhrKCdwYXN0ZScsIFN0cmluZyhjLmlkKSk7CiAg
ICAgICAgICAgIH0KICAgICAgICB9CiAgICB9OwoKICAgIC8vIEFISyBFbnRlciBo
b3RrZXkgbGFuZHMgaGVyZSAoV2ViVmlldyBtYXkgbm90IHJlY2VpdmUgdGhlIGtl
eSB3aGlsZSB1bnBpbm5lZCkKICAgIHdpbmRvdy5fX2VkaXRUaXRsZSA9ICgpID0+
IHsKICAgICAgICBsZXQgYyA9IG51bGw7CiAgICAgICAgaWYgKHNlbGVjdGVkSWQp
CiAgICAgICAgICAgIGMgPSBhbGxDbGlwcy5maW5kKHggPT4gK3guaWQgPT09ICtz
ZWxlY3RlZElkKSB8fCBudWxsOwogICAgICAgIGlmICghYyAmJiBjdHhDbGlwKQog
ICAgICAgICAgICBjID0gY3R4Q2xpcDsKICAgICAgICBpZiAoIWMpIHsKICAgICAg
ICAgICAgY29uc3QgdmlzID0gdmlzaWJsZUxpc3QoKTsKICAgICAgICAgICAgaWYg
KHZpcy5sZW5ndGgpIGMgPSB2aXNbMF07CiAgICAgICAgfQogICAgICAgIGlmICgh
YykgcmV0dXJuOwogICAgICAgIG9wZW5UaXRsZURsZyhjKTsKICAgIH07CgogICAg
d2luZG93Ll9fb25FbnRlciA9ICgpID0+IHsKICAgICAgICBjb25zdCB0ZCA9IGRv
Y3VtZW50LmdldEVsZW1lbnRCeUlkKCd0aXRsZS1kbGcnKTsKICAgICAgICBpZiAo
dGQgJiYgdGQuY2xhc3NMaXN0LmNvbnRhaW5zKCdvbicpKSB7CiAgICAgICAgICAg
IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0aXRsZS1vaycpPy5jbGljaygpOwog
ICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGlmIChkb2N1bWVu
dC5hY3RpdmVFbGVtZW50Py5pZCA9PT0gJ3RpdGxlLWlucHV0JykgewogICAgICAg
ICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGl0bGUtb2snKT8uY2xpY2so
KTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICAvLyBUeXBp
bmcgaW4gc2VhcmNoOiBFbnRlciBzaG91bGQgbm90IHBhc3RlCiAgICAgICAgaWYg
KGRvY3VtZW50LmFjdGl2ZUVsZW1lbnQ/LmlkID09PSAnc2VhcmNoJykKICAgICAg
ICAgICAgcmV0dXJuOwogICAgICAgIHdpbmRvdy5fX25hdiAmJiB3aW5kb3cuX19u
YXYoJ2VudGVyJyk7CiAgICB9OwoKICAgIGNvbnN0IFRBQl9PUkRFUiA9IFsnYWxs
JywgJ3RleHQnLCAnaW1hZ2UnLCAnZmlsZScsICdsaW5rJywgJ3Bpbm5lZCddOwog
ICAgd2luZG93Ll9fY3ljbGVUYWIgPSBkaXIgPT4gewogICAgICAgIGNvbnN0IGkg
PSBNYXRoLm1heCgwLCBUQUJfT1JERVIuaW5kZXhPZihjdXJUYWIpKTsKICAgICAg
ICBjb25zdCBuZXh0ID0gVEFCX09SREVSWyhpICsgKGRpciB8IDApICsgVEFCX09S
REVSLmxlbmd0aCAqIDEwKSAlIFRBQl9PUkRFUi5sZW5ndGhdOwogICAgICAgIHNl
dFRhYihuZXh0KTsKICAgIH07CiAgICB3aW5kb3cuX19vblBhbmVsU2hvdyA9ICgp
ID0+IHsKICAgICAgICAvLyBEbyBOT1QgZm9jdXMgV2ViVmlldyDigJQga2VlcCBl
ZGl0b3IgY2FyZXQvZm9jdXMgKEFISyBoYW5kbGVzIGtleXMgdmlhICNIb3RJZikK
ICAgICAgICAvLyBDb2xsYXBzZSBzZWFyY2ggVUkgYW5kIGFsd2F5cyBsYW5kIG9u
IOWFqOmDqCBldmVyeSB0aW1lIHRoZSBwYW5lbCBvcGVucwogICAgICAgIHRyeSB7
IGhpZGVDdHgoKTsgfSBjYXRjaCB7fQogICAgICAgIHRyeSB7IGNsb3NlVGl0bGVE
bGcoKTsgfSBjYXRjaCB7fQogICAgICAgIHRyeSB7CiAgICAgICAgICAgIGNvbnN0
IHdyYXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLXdyYXAnKTsK
ICAgICAgICAgICAgY29uc3Qgc3JjaCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlk
KCdzZWFyY2gnKTsKICAgICAgICAgICAgY29uc3Qgc2NsciA9IGRvY3VtZW50Lmdl
dEVsZW1lbnRCeUlkKCdzZWFyY2gtY2xyJyk7CiAgICAgICAgICAgIGlmICh3cmFw
KSB3cmFwLmNsYXNzTGlzdC5yZW1vdmUoJ29wZW4nKTsKICAgICAgICAgICAgaWYg
KHNyY2gpIHsKICAgICAgICAgICAgICAgIHNyY2gudmFsdWUgPSAnJzsKICAgICAg
ICAgICAgICAgIHNyY2guY2xhc3NMaXN0LnJlbW92ZSgnaGFzLXZhbCcpOwogICAg
ICAgICAgICAgICAgdHJ5IHsgc3JjaC5ibHVyKCk7IH0gY2F0Y2gge30KICAgICAg
ICAgICAgfQogICAgICAgICAgICBpZiAoc2Nscikgc2Nsci5zdHlsZS5kaXNwbGF5
ID0gJ25vbmUnOwogICAgICAgICAgICBxdWVyeSA9ICcnOwogICAgICAgICAgICB0
b2RheU9ubHkgPSBmYWxzZTsKICAgICAgICAgICAgdHJ5IHsKICAgICAgICAgICAg
ICAgIGNvbnN0IGJ0blRvZGF5ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0
bi10b2RheScpOwogICAgICAgICAgICAgICAgaWYgKGJ0blRvZGF5KSBidG5Ub2Rh
eS5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgICAgICB9IGNhdGNoIHt9
CiAgICAgICAgICAgIGNvbnN0IHByZXZUYWIgPSBjdXJUYWI7CiAgICAgICAgICAg
IGN1clRhYiA9ICdhbGwnOwogICAgICAgICAgICBsb2FkaW5nTW9yZSA9IGZhbHNl
OwogICAgICAgICAgICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcudGFiJyku
Zm9yRWFjaChlbCA9PgogICAgICAgICAgICAgICAgZWwuY2xhc3NMaXN0LnRvZ2ds
ZSgnb24nLCBlbC5kYXRhc2V0LnRhYiA9PT0gJ2FsbCcpKTsKICAgICAgICAgICAg
aWYgKHByZXZUYWIgPT09ICdsaW5rJykKICAgICAgICAgICAgICAgIHN0b3BMaW5r
TWVkaWEoKTsKICAgICAgICAgICAgbGlua0xvYWRBY3RpdmUgPSBmYWxzZTsKICAg
ICAgICAgICAgYWhrKCdibHVyUGFuZWwnKTsKICAgICAgICAgICAgLy8gRGF0YSBw
dXNoOiBBSEsgU2hvd1BhbmVsIOKGkiBTZXRWaWV3KCJhbGwiLCDigKYpOyBrZWVw
IHJlcXVlc3RWaWV3IGFzIHN5bmMgZmFsbGJhY2sKICAgICAgICAgICAgcmVxdWVz
dFZpZXcoKTsKICAgICAgICB9IGNhdGNoIHt9CiAgICAgICAgLy8gUHJlZmVyIGZp
cnN0IGl0ZW0gZXZlcnkgb3BlbjsgYXBwbHkgYWdhaW4gd2hlbiBfX3VwZGF0ZUNs
aXBzL3JlbmRlciBydW5zCiAgICAgICAgc2VsZWN0Rmlyc3RPblNob3cgPSB0cnVl
OwogICAgICAgIGxvY2F0ZUFjdGl2ZSA9IGZhbHNlOwogICAgICAgIHVwZGF0ZUxv
Y2F0ZUJ0bigpOwogICAgICAgIGNsZWFyTXVsdGkoKTsKICAgICAgICBjb25zdCB2
aXMgPSB2aXNpYmxlTGlzdCgpOwogICAgICAgIGlmICh2aXMubGVuZ3RoKSB7CiAg
ICAgICAgICAgIHNlbGVjdGVkSWQgPSB2aXNbMF0uaWQ7CiAgICAgICAgICAgIGxp
c3RFbC5zY3JvbGxUb3AgPSAwOwogICAgICAgIH0KICAgICAgICBzeW5jSXRlbUhp
Z2hsaWdodCgpOwogICAgfTsKCiAgICBmdW5jdGlvbiBjdHhCaW5kKGlkLCBmbikg
ewogICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKS5hZGRFdmVudExp
c3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgICAgICBlLnN0b3BQcm9wYWdh
dGlvbigpOwogICAgICAgICAgICBpZiAoY3R4Q2xpcCkgZm4oY3R4Q2xpcCk7CiAg
ICAgICAgICAgIGhpZGVDdHgoKTsKICAgICAgICB9KTsKICAgIH0KICAgIGN0eEJp
bmQoJ2MtY29weScsICBjID0+IGFoaygnY29weUJ5SWQnLCAgICAgU3RyaW5nKGMu
aWQpKSk7CiAgICBjdHhCaW5kKCdjLXBhc3RlJywgYyA9PiB7CiAgICAgICAgbWFy
a1Bhc3RlZExvY2FsKGMuaWQpOwogICAgICAgIGFoaygncGFzdGUnLCBTdHJpbmco
Yy5pZCkpOwogICAgfSk7CiAgICBjdHhCaW5kKCdjLXBpbicsICAgYyA9PiBhaGso
J3BpbicsICAgICAgICAgICBTdHJpbmcoYy5pZCkpKTsKICAgIGN0eEJpbmQoJ2Mt
dG9wJywgICBjID0+IGFoaygnbW92ZVRvVG9wJywgICAgIFN0cmluZyhjLmlkKSkp
OwogICAgY3R4QmluZCgnYy1jbGVhci1wYXN0ZWQnLCBjID0+IGFoaygnY2xlYXJQ
YXN0ZWQnLCBTdHJpbmcoYy5pZCkpKTsKICAgIGN0eEJpbmQoJ2MtZGVsJywgICBj
ID0+IGFoaygnZGVsZXRlJywgICAgICAgIFN0cmluZyhjLmlkKSkpOwogICAgY3R4
QmluZCgnYy10aXRsZScsIGMgPT4gb3BlblRpdGxlRGxnKGMpKTsKICAgIGN0eEJp
bmQoJ2MtbWVyZ2UnLCBjID0+IHsKICAgICAgICBjb25zdCBpZHMgPSAobXVsdGlJ
ZHMubGVuZ3RoID49IDIpID8gbXVsdGlJZHMuc2xpY2UoKSA6IFtdOwogICAgICAg
IGlmIChpZHMubGVuZ3RoIDwgMikgcmV0dXJuOwogICAgICAgIGlmICghaWRzLmlu
Y2x1ZGVzKCtjLmlkKSkgaWRzLnB1c2goK2MuaWQpOwogICAgICAgIGFoaygnbWVy
Z2VGYXYnLCBpZHMuam9pbignLCcpKTsKICAgICAgICBjbGVhck11bHRpKCk7CiAg
ICB9KTsKICAgIGN0eEJpbmQoJ2MtdW5tZXJnZScsIGMgPT4gewogICAgICAgIGFo
aygndW5tZXJnZUZhdicsIFN0cmluZyhjLmlkKSk7CiAgICAgICAgY2xlYXJNdWx0
aSgpOwogICAgfSk7CgogICAgY29uc3QgdGl0bGVEbGcgPSBkb2N1bWVudC5nZXRF
bGVtZW50QnlJZCgndGl0bGUtZGxnJyk7CiAgICBjb25zdCB0aXRsZUlucHV0ID0g
ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RpdGxlLWlucHV0Jyk7CiAgICBsZXQg
dGl0bGVEbGdDbGlwID0gbnVsbDsKICAgIGZ1bmN0aW9uIGNsb3NlVGl0bGVEbGco
KSB7CiAgICAgICAgaWYgKHRpdGxlRGxnKSB0aXRsZURsZy5jbGFzc0xpc3QucmVt
b3ZlKCdvbicpOwogICAgICAgIHRpdGxlRGxnQ2xpcCA9IG51bGw7CiAgICB9CiAg
ICBmdW5jdGlvbiBvcGVuVGl0bGVEbGcoYykgewogICAgICAgIGhpZGVDdHgoKTsK
ICAgICAgICB0aXRsZURsZ0NsaXAgPSBjOwogICAgICAgIGlmICh0aXRsZUlucHV0
KSB0aXRsZUlucHV0LnZhbHVlID0gU3RyaW5nKGMuZmF2VGl0bGUgfHwgJycpLnRy
aW0oKTsKICAgICAgICBpZiAodGl0bGVEbGcpIHRpdGxlRGxnLmNsYXNzTGlzdC5h
ZGQoJ29uJyk7CiAgICAgICAgYWhrKCdmb2N1c1BhbmVsJyk7CiAgICAgICAgcmVx
dWVzdEFuaW1hdGlvbkZyYW1lKCgpID0+IHsKICAgICAgICAgICAgdHJ5IHsgdGl0
bGVJbnB1dC5mb2N1cygpOyB0aXRsZUlucHV0LnNlbGVjdCgpOyB9IGNhdGNoIHt9
CiAgICAgICAgfSk7CiAgICB9CiAgICBpZiAodGl0bGVEbGcpIHsKICAgICAgICB0
aXRsZURsZy5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAg
ICAgICBpZiAoZS50YXJnZXQgPT09IHRpdGxlRGxnKSBjbG9zZVRpdGxlRGxnKCk7
CiAgICAgICAgfSk7CiAgICB9CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgn
dGl0bGUtY2FuY2VsJyk/LmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7
CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICBjbG9zZVRpdGxl
RGxnKCk7CiAgICAgICAgYWhrKCdibHVyUGFuZWwnKTsKICAgIH0pOwogICAgZG9j
dW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RpdGxlLW9rJyk/LmFkZEV2ZW50TGlzdGVu
ZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsK
ICAgICAgICBpZiAoIXRpdGxlRGxnQ2xpcCkgcmV0dXJuOwogICAgICAgIGNvbnN0
IHQgPSBTdHJpbmcodGl0bGVJbnB1dD8udmFsdWUgfHwgJycpLnRyaW0oKS5zbGlj
ZSgwLCA4MCk7CiAgICAgICAgY29uc3QgaWQgPSBTdHJpbmcodGl0bGVEbGdDbGlw
LmlkKTsKICAgICAgICAvLyBPcHRpbWlzdGljIGxvY2FsIHVwZGF0ZQogICAgICAg
IGNvbnN0IGhpdCA9IGFsbENsaXBzLmZpbmQoeCA9PiAreC5pZCA9PT0gK2lkKTsK
ICAgICAgICBpZiAoaGl0KSBoaXQuZmF2VGl0bGUgPSB0OwogICAgICAgIHRpdGxl
RGxnQ2xpcC5mYXZUaXRsZSA9IHQ7CiAgICAgICAgY2xvc2VUaXRsZURsZygpOwog
ICAgICAgIGFoaygnc2V0RmF2VGl0bGUnLCBpZCwgdCk7CiAgICAgICAgYWhrKCdi
bHVyUGFuZWwnKTsKICAgICAgICByZW5kZXIoKTsKICAgIH0pOwogICAgdGl0bGVJ
bnB1dD8uYWRkRXZlbnRMaXN0ZW5lcigna2V5ZG93bicsIGUgPT4gewogICAgICAg
IGlmIChlLmtleSA9PT0gJ0VudGVyJykgewogICAgICAgICAgICBlLnByZXZlbnRE
ZWZhdWx0KCk7CiAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAg
ICAgICAgIGUuc3RvcEltbWVkaWF0ZVByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAg
IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0aXRsZS1vaycpPy5jbGljaygpOwog
ICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGlmIChlLmtleSA9
PT0gJ0VzY2FwZScpIHsKICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwog
ICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICBjbG9z
ZVRpdGxlRGxnKCk7CiAgICAgICAgICAgIGFoaygnYmx1clBhbmVsJyk7CiAgICAg
ICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgZS5zdG9wUHJvcGFnYXRp
b24oKTsKICAgIH0sIHRydWUpOwoKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlk
KCd0YWJzJykuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAg
ICBjb25zdCB0YWIgPSBlLnRhcmdldC5jbG9zZXN0KCcudGFiJyk7CiAgICAgICAg
aWYgKCF0YWIgfHwgZS50YXJnZXQuY2xvc2VzdCgnI3RhYi1hY3Rpb25zJykpIHJl
dHVybjsKICAgICAgICBzZXRUYWIodGFiLmRhdGFzZXQudGFiKTsKICAgIH0pOwoK
ICAgIGNvbnN0IHNyY2hXcmFwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Nl
YXJjaC13cmFwJyk7CiAgICBjb25zdCBidG5TZWFyY2ggPSBkb2N1bWVudC5nZXRF
bGVtZW50QnlJZCgnYnRuLXNlYXJjaCcpOwogICAgY29uc3QgYnRuTG9jYXRlID0g
ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi1sb2NhdGUnKTsKICAgIGNvbnN0
IGJ0blRvZGF5ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi10b2RheScp
OwogICAgY29uc3Qgc3JjaCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFy
Y2gnKTsKICAgIGNvbnN0IHNjbHIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgn
c2VhcmNoLWNscicpOwogICAgbGV0IGRlYjsKCiAgICB1cGRhdGVMb2NhdGVCdG4o
KTsKICAgIGlmIChidG5Mb2NhdGUpIHsKICAgICAgICBidG5Mb2NhdGUuYWRkRXZl
bnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICAgICAgZS5zdG9wUHJv
cGFnYXRpb24oKTsKICAgICAgICAgICAganVtcFRvTGFzdFBhc3RlKCk7CiAgICAg
ICAgfSk7CiAgICB9CgogICAgYnRuVG9kYXkuYWRkRXZlbnRMaXN0ZW5lcignbW91
c2Vkb3duJywgZSA9PiB7CiAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAg
ICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICB9KTsKICAgIGJ0blRvZGF5LmFk
ZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgZS5zdG9wUHJv
cGFnYXRpb24oKTsKICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAg
dG9kYXlPbmx5ID0gIXRvZGF5T25seTsKICAgICAgICBidG5Ub2RheS5jbGFzc0xp
c3QudG9nZ2xlKCdvbicsIHRvZGF5T25seSk7CiAgICAgICAgbGlzdEVsLnNjcm9s
bFRvcCA9IDA7CiAgICAgICAgcmVxdWVzdFZpZXcoKTsKICAgICAgICB0cnkgeyBz
cmNoLmZvY3VzKCk7IH0gY2F0Y2gge30KICAgIH0pOwoKICAgIGZ1bmN0aW9uIG9w
ZW5TZWFyY2goKSB7CiAgICAgICAgaWYgKHNyY2hXcmFwLmNsYXNzTGlzdC5jb250
YWlucygnb3BlbicpKSB7CiAgICAgICAgICAgIGFoaygnZm9jdXNQYW5lbCcpOwog
ICAgICAgICAgICB0cnkgeyBzcmNoLmZvY3VzKCk7IH0gY2F0Y2gge30KICAgICAg
ICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBzcmNoV3JhcC5jbGFzc0xp
c3QuYWRkKCdvcGVuJyk7CiAgICAgICAgLy8gRGVmYXVsdDog5b2T5aSp77yI5YW2
5a6D6aG177yJ77yb5pS26JeP6aG16buY6K6k5pCc5YWo6YOoCiAgICAgICAgY29u
c3Qgd2FudFRvZGF5ID0gKGN1clRhYiAhPT0gJ3Bpbm5lZCcpOwogICAgICAgIGlm
ICh0b2RheU9ubHkgIT09IHdhbnRUb2RheSkgewogICAgICAgICAgICB0b2RheU9u
bHkgPSB3YW50VG9kYXk7CiAgICAgICAgICAgIGJ0blRvZGF5LmNsYXNzTGlzdC50
b2dnbGUoJ29uJywgdG9kYXlPbmx5KTsKICAgICAgICAgICAgbGlzdEVsLnNjcm9s
bFRvcCA9IDA7CiAgICAgICAgICAgIHJlcXVlc3RWaWV3KCk7CiAgICAgICAgfSBl
bHNlIHsKICAgICAgICAgICAgYnRuVG9kYXkuY2xhc3NMaXN0LnRvZ2dsZSgnb24n
LCB0b2RheU9ubHkpOwogICAgICAgIH0KICAgICAgICBhaGsoJ2ZvY3VzUGFuZWwn
KTsKICAgICAgICByZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4gewogICAgICAg
ICAgICB0cnkgeyBzcmNoLmZvY3VzKCk7IH0gY2F0Y2gge30KICAgICAgICB9KTsK
ICAgIH0KICAgIGZ1bmN0aW9uIGNsb3NlU2VhcmNoVWkoKSB7CiAgICAgICAgc3Jj
aFdyYXAuY2xhc3NMaXN0LnJlbW92ZSgnb3BlbicpOwogICAgICAgIGlmICghc3Jj
aC52YWx1ZSkgewogICAgICAgICAgICBzcmNoLmNsYXNzTGlzdC5yZW1vdmUoJ2hh
cy12YWwnKTsKICAgICAgICAgICAgc2Nsci5zdHlsZS5kaXNwbGF5ID0gJ25vbmUn
OwogICAgICAgICAgICAvLyBMZWF2aW5nIHNlYXJjaCB3aXRoIGVtcHR5IHF1ZXJ5
IOKGkiBkcm9wIHRvZGF5IGZpbHRlcgogICAgICAgICAgICBpZiAodG9kYXlPbmx5
KSB7CiAgICAgICAgICAgICAgICB0b2RheU9ubHkgPSBmYWxzZTsKICAgICAgICAg
ICAgICAgIGJ0blRvZGF5LmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAg
ICAgICAgICByZXF1ZXN0VmlldygpOwogICAgICAgICAgICB9CiAgICAgICAgfQog
ICAgfQogICAgd2luZG93Ll9fb3BlblNlYXJjaCA9IG9wZW5TZWFyY2g7CiAgICAv
LyBDYXB0dXJlIEN0cmwrRiBpbnNpZGUgV2ViVmlldyAoQ2hyb21pdW0gZmluZCBp
cyBkaXNhYmxlZCwgYnV0IHN0aWxsIGhhbmRsZSBoZXJlKQogICAgZG9jdW1lbnQu
YWRkRXZlbnRMaXN0ZW5lcigna2V5ZG93bicsIGUgPT4gewogICAgICAgIGlmICgo
ZS5jdHJsS2V5IHx8IGUubWV0YUtleSkgJiYgIWUuYWx0S2V5ICYmIChlLmtleSA9
PT0gJ2YnIHx8IGUua2V5ID09PSAnRicpKSB7CiAgICAgICAgICAgIGUucHJldmVu
dERlZmF1bHQoKTsKICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAg
ICAgICAgICAgb3BlblNlYXJjaCgpOwogICAgICAgIH0KICAgIH0sIHRydWUpOwog
ICAgYnRuU2VhcmNoLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAg
ICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICBvcGVuU2VhcmNoKCk7
CiAgICB9KTsKICAgIHNyY2guYWRkRXZlbnRMaXN0ZW5lcignaW5wdXQnLCAoKSA9
PiB7CiAgICAgICAgcXVlcnkgPSBzcmNoLnZhbHVlOwogICAgICAgIHNyY2guY2xh
c3NMaXN0LnRvZ2dsZSgnaGFzLXZhbCcsICEhcXVlcnkpOwogICAgICAgIHNjbHIu
c3R5bGUuZGlzcGxheSA9IHF1ZXJ5ID8gJ2Jsb2NrJyA6ICdub25lJzsKICAgICAg
ICBsaXN0RWwuc2Nyb2xsVG9wID0gMDsKICAgICAgICBjbGVhclRpbWVvdXQoZGVi
KTsKICAgICAgICBkZWIgPSBzZXRUaW1lb3V0KHJlcXVlc3RWaWV3LCA4MCk7CiAg
ICB9KTsKICAgIHNyY2guYWRkRXZlbnRMaXN0ZW5lcignZm9jdXMnLCAoKSA9PiB7
CiAgICAgICAgYWhrKCdmb2N1c1BhbmVsJyk7CiAgICB9KTsKICAgIHNyY2guYWRk
RXZlbnRMaXN0ZW5lcignYmx1cicsICgpID0+IHsKICAgICAgICBzZXRUaW1lb3V0
KCgpID0+IHsKICAgICAgICAgICAgaWYgKGRvY3VtZW50LmFjdGl2ZUVsZW1lbnQg
PT09IHNyY2gpIHJldHVybjsKICAgICAgICAgICAgLy8gQ2xlYXIgLyDlvZPlpKkg
YnV0dG9uIGNsaWNrIGJsdXJzIOKAlCBrZWVwIHNlYXJjaCBvcGVuCiAgICAgICAg
ICAgIGlmIChkb2N1bWVudC5hY3RpdmVFbGVtZW50ID09PSBzY2xyIHx8IHNjbHIu
Y29udGFpbnMoZG9jdW1lbnQuYWN0aXZlRWxlbWVudCkpIHJldHVybjsKICAgICAg
ICAgICAgaWYgKGRvY3VtZW50LmFjdGl2ZUVsZW1lbnQgPT09IGJ0blRvZGF5IHx8
IGJ0blRvZGF5LmNvbnRhaW5zKGRvY3VtZW50LmFjdGl2ZUVsZW1lbnQpKSByZXR1
cm47CiAgICAgICAgICAgIGNsb3NlU2VhcmNoVWkoKTsKICAgICAgICAgICAgYWhr
KCdibHVyUGFuZWwnKTsKICAgICAgICB9LCAxMjApOwogICAgfSk7CiAgICBzcmNo
LmFkZEV2ZW50TGlzdGVuZXIoJ2tleWRvd24nLCBlID0+IHsKICAgICAgICAvLyBD
dHJsK0kgLyBDdHJsK0s6IG1vdmUgY2xpcCBzZWxlY3Rpb24gKG5vdCBpbnNlcnQg
Y2hhciAvIGJyb3dzZXIgc2hvcnRjdXQpCiAgICAgICAgaWYgKChlLmN0cmxLZXkg
fHwgZS5tZXRhS2V5KSAmJiAoZS5rZXkgPT09ICdpJyB8fCBlLmtleSA9PT0gJ0kn
KSkgewogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAg
IGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgIHdpbmRvdy5fX25hdiAm
JiB3aW5kb3cuX19uYXYoJ3VwJyk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAg
ICB9CiAgICAgICAgaWYgKChlLmN0cmxLZXkgfHwgZS5tZXRhS2V5KSAmJiAoZS5r
ZXkgPT09ICdrJyB8fCBlLmtleSA9PT0gJ0snKSkgewogICAgICAgICAgICBlLnBy
ZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7
CiAgICAgICAgICAgIHdpbmRvdy5fX25hdiAmJiB3aW5kb3cuX19uYXYoJ2Rvd24n
KTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBpZiAoZS5r
ZXkgPT09ICdBcnJvd0Rvd24nKSB7CiAgICAgICAgICAgIGUucHJldmVudERlZmF1
bHQoKTsKICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAg
ICAgd2luZG93Ll9fbmF2ICYmIHdpbmRvdy5fX25hdignZG93bicpOwogICAgICAg
ICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGlmIChlLmtleSA9PT0gJ0Fy
cm93VXAnKSB7CiAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAg
ICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgd2luZG93Ll9f
bmF2ICYmIHdpbmRvdy5fX25hdigndXAnKTsKICAgICAgICAgICAgcmV0dXJuOwog
ICAgICAgIH0KICAgICAgICBpZiAoZS5rZXkgPT09ICdFc2NhcGUnKSB7CiAgICAg
ICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgZS5zdG9wUHJv
cGFnYXRpb24oKTsKICAgICAgICAgICAgLy8gQWx3YXlzIGRpc21pc3MgdGhlIHdo
b2xlIHBhbmVsIChub3QganVzdCB0aGUgc2VhcmNoIGZpZWxkKQogICAgICAgICAg
ICBpZiAoIXBpbm5lZFVJKSBhaGsoJ2hpZGUnKTsKICAgICAgICAgICAgcmV0dXJu
OwogICAgICAgIH0KICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgfSk7
CiAgICBzY2xyLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAg
ICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICBzcmNoLnZhbHVlID0gcXVl
cnkgPSAnJzsKICAgICAgICBzY2xyLnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAg
ICAgICAgc3JjaC5jbGFzc0xpc3QucmVtb3ZlKCdoYXMtdmFsJyk7CiAgICAgICAg
cmVxdWVzdFZpZXcoKTsKICAgICAgICBhaGsoJ2ZvY3VzUGFuZWwnKTsKICAgICAg
ICBzcmNoLmZvY3VzKCk7CiAgICB9KTsKCiAgICBjb25zdCBUQUJfTkFNRVMgPSB7
IGFsbDogJ+WFqOmDqCcsIHRleHQ6ICfmlofmnKwnLCBpbWFnZTogJ+WbvuWDjycs
IGZpbGU6ICfmlofku7YnLCBsaW5rOiAn6ZO+5o6lJywgcGlubmVkOiAn5pS26JeP
JyB9OwogICAgY29uc3QgY2xyRGxnID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQo
J2Nsci1kbGcnKTsKICAgIGNvbnN0IGNsckFsbENiID0gZG9jdW1lbnQuZ2V0RWxl
bWVudEJ5SWQoJ2Nsci1hbGwnKTsKICAgIGZ1bmN0aW9uIG9wZW5DbGVhckRsZygp
IHsKICAgICAgICBjb25zdCBuYW1lID0gVEFCX05BTUVTW2N1clRhYl0gfHwgJ+W9
k+WJjSc7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Nsci10aXRs
ZScpLnRleHRDb250ZW50ID0gJ+a4heepuuOAjCcgKyBuYW1lICsgJ+OAje+8nyc7
CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Nsci1kZXNjJykudGV4
dENvbnRlbnQgPSBjdXJUYWIgPT09ICdwaW5uZWQnCiAgICAgICAgICAgID8gJ+m7
mOiupOS7hea4heepuuW9k+WkqeeahOaUtuiXj+mhueOAguWLvumAieOAjOa4heep
uuaJgOacieOAjeWPr+a4hemZpOivpemAiemhueWNoeWFqOmDqOWGheWuueOAgicK
ICAgICAgICAgICAgOiAn5LuF5riF56m65b2T5YmN6YCJ6aG55Y2h44CC6buY6K6k
5Y+q5riF5b2T5aSp77yb5pS26JeP6aG55LiN5Lya6KKr5riF6Zmk44CC5Yu+6YCJ
44CM5riF56m65omA5pyJ44CN5Y+v5riF6Zmk6K+l6YCJ6aG55Y2h5YWo6YOo5pel
5pyf44CCJzsKICAgICAgICBjbHJBbGxDYi5jaGVja2VkID0gZmFsc2U7CiAgICAg
ICAgY2xyRGxnLmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAgICB9CiAgICBmdW5jdGlv
biBjbG9zZUNsZWFyRGxnKCkgewogICAgICAgIGNsckRsZy5jbGFzc0xpc3QucmVt
b3ZlKCdvbicpOwogICAgfQogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0
bi1jbHInKS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAg
IGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgb3BlbkNsZWFyRGxnKCk7CiAg
ICB9KTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjbHItY2FuY2VsJyku
YWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICBlLnN0b3BQ
cm9wYWdhdGlvbigpOwogICAgICAgIGNsb3NlQ2xlYXJEbGcoKTsKICAgIH0pOwog
ICAgY2xyRGxnLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAg
ICAgaWYgKGUudGFyZ2V0ID09PSBjbHJEbGcpIGNsb3NlQ2xlYXJEbGcoKTsKICAg
IH0pOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Nsci1vaycpLmFkZEV2
ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgZS5zdG9wUHJvcGFn
YXRpb24oKTsKICAgICAgICBjb25zdCBzY29wZSA9IGNsckFsbENiLmNoZWNrZWQg
PyAnYWxsJyA6ICd0b2RheSc7CiAgICAgICAgY2xvc2VDbGVhckRsZygpOwogICAg
ICAgIGFoaygnY2xlYXInLCBjdXJUYWIsIHNjb3BlKTsKICAgIH0pOwogICAgZG9j
dW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ211bHRpLWNudCcpLmFkZEV2ZW50TGlzdGVu
ZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsK
ICAgICAgICBjbGVhck11bHRpKCk7CiAgICB9KTsKICAgIGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCdidG4tcGluJykuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBl
ID0+IHsKICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgIHBpbm5l
ZFVJID0gIXBpbm5lZFVJOwogICAgICAgIGUuY3VycmVudFRhcmdldC5jbGFzc0xp
c3QudG9nZ2xlKCdvbicsIHBpbm5lZFVJKTsKICAgICAgICBhaGsoJ3RvZ2dsZVBp
bicsIHBpbm5lZFVJID8gJzEnIDogJzAnKTsKICAgIH0pOwoKICAgIHdpbmRvdy5f
X3VwZGF0ZUNsaXBzID0gcGF5bG9hZCA9PiB7CiAgICAgICAgLy8gS2VlcCBwcmV2
aW91cyBzY3JvbGwgZm9yIGxvYWQtbW9yZTsgcmVzZXQgd2hlbiBvcGVuaW5nIHBh
bmVsIHRvIGZpcnN0IGl0ZW0KICAgICAgICBjb25zdCBrZWVwU2Nyb2xsID0gIXNl
bGVjdEZpcnN0T25TaG93OwogICAgICAgIGNvbnN0IHN0ID0gbGlzdEVsLnNjcm9s
bFRvcDsKICAgICAgICBpZiAoQXJyYXkuaXNBcnJheShwYXlsb2FkKSkgewogICAg
ICAgICAgICBhbGxDbGlwcyA9IHBheWxvYWQ7CiAgICAgICAgICAgIGRpc2tUb3Rh
bCA9IHBheWxvYWQubGVuZ3RoOwogICAgICAgIH0gZWxzZSBpZiAocGF5bG9hZCAm
JiB0eXBlb2YgcGF5bG9hZCA9PT0gJ29iamVjdCcpIHsKICAgICAgICAgICAgZGlz
a1RvdGFsID0gTnVtYmVyKHBheWxvYWQudG90YWwpIHx8IDA7CiAgICAgICAgICAg
IGNvbnN0IGl0ZW1zID0gQXJyYXkuaXNBcnJheShwYXlsb2FkLml0ZW1zKSA/IHBh
eWxvYWQuaXRlbXMgOiBbXTsKICAgICAgICAgICAgaWYgKHBheWxvYWQuYXBwZW5k
KSB7CiAgICAgICAgICAgICAgICBjb25zdCBzZWVuID0gbmV3IFNldChhbGxDbGlw
cy5tYXAoYyA9PiArYy5pZCkpOwogICAgICAgICAgICAgICAgaXRlbXMuZm9yRWFj
aChpdCA9PiB7CiAgICAgICAgICAgICAgICAgICAgaWYgKCFzZWVuLmhhcygraXQu
aWQpKSBhbGxDbGlwcy5wdXNoKGl0KTsKICAgICAgICAgICAgICAgIH0pOwogICAg
ICAgICAgICB9IGVsc2UgewogICAgICAgICAgICAgICAgYWxsQ2xpcHMgPSBpdGVt
czsKICAgICAgICAgICAgfQogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgIGFs
bENsaXBzID0gW107CiAgICAgICAgICAgIGRpc2tUb3RhbCA9IDA7CiAgICAgICAg
fQogICAgICAgIHJlbmRlcigpOwogICAgICAgIGlmIChrZWVwU2Nyb2xsKQogICAg
ICAgICAgICBsaXN0RWwuc2Nyb2xsVG9wID0gc3Q7CiAgICAgICAgZWxzZQogICAg
ICAgICAgICBsaXN0RWwuc2Nyb2xsVG9wID0gMDsKICAgIH07CiAgICB3aW5kb3cu
X19sb2FkTW9yZURvbmUgPSAoKSA9PiB7IGxvYWRpbmdNb3JlID0gZmFsc2U7IH07
CiAgICB3aW5kb3cuX19zZXRQaW5uZWQgPSB2ID0+IHsKICAgICAgICBwaW5uZWRV
SSA9ICEhdjsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLXBp
bicpLmNsYXNzTGlzdC50b2dnbGUoJ29uJywgcGlubmVkVUkpOwogICAgfTsKCiAg
ICByZXF1ZXN0VmlldygpOwogICAgcmVuZGVyKCk7CgogICAgLyogTG9jYWwgZGF5
L25pZ2h0IGFtYmllbmNlICovCiAgICAoZnVuY3Rpb24gKCkgewogICAgICAgIGNv
bnN0IGFwcCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdhcHAnKTsKICAgICAg
ICBjb25zdCBtb29uID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3d4LW1vb24n
KTsKICAgICAgICBjb25zdCBzdGFyc0VsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ3d4LXN0YXJzJyk7CiAgICAgICAgaWYgKCFhcHAgfHwgIW1vb24gfHwgIXN0
YXJzRWwpIHJldHVybjsKICAgICAgICBmb3IgKGxldCBpID0gMDsgaSA8IDI4OyBp
KyspIHsKICAgICAgICAgICAgY29uc3Qgc3QgPSBkb2N1bWVudC5jcmVhdGVFbGVt
ZW50KCdpJyk7CiAgICAgICAgICAgIHN0LmNsYXNzTmFtZSA9ICd3eC1zdGFyJyAr
IChpICUgNSA9PT0gMCA/ICcgYmlnJyA6ICcnKTsKICAgICAgICAgICAgc3Quc3R5
bGUubGVmdCA9ICg0ICsgTWF0aC5yYW5kb20oKSAqIDkyKSArICclJzsKICAgICAg
ICAgICAgc3Quc3R5bGUudG9wID0gKDMgKyBNYXRoLnJhbmRvbSgpICogNDgpICsg
JyUnOwogICAgICAgICAgICBzdC5zdHlsZS5hbmltYXRpb25EZWxheSA9IChNYXRo
LnJhbmRvbSgpICogMi44KSArICdzJzsKICAgICAgICAgICAgc3RhcnNFbC5hcHBl
bmRDaGlsZChzdCk7CiAgICAgICAgfQogICAgICAgIGNvbnN0IHN5bmMgPSAoKSA9
PiB7CiAgICAgICAgICAgIGNvbnN0IGggPSBuZXcgRGF0ZSgpLmdldEhvdXJzKCk7
CiAgICAgICAgICAgIGNvbnN0IG5pZ2h0ID0gaCA8IDYgfHwgaCA+PSAxOTsKICAg
ICAgICAgICAgYXBwLmNsYXNzTGlzdC50b2dnbGUoJ3d4LW5pZ2h0JywgbmlnaHQp
OwogICAgICAgICAgICBtb29uLmNsYXNzTGlzdC50b2dnbGUoJ29uJywgbmlnaHQp
OwogICAgICAgICAgICBzdGFyc0VsLmNsYXNzTGlzdC50b2dnbGUoJ29uJywgbmln
aHQpOwogICAgICAgIH07CiAgICAgICAgc3luYygpOwogICAgICAgIHNldEludGVy
dmFsKHN5bmMsIDYwICogMTAwMCk7CiAgICB9KSgpOwo8L3NjcmlwdD4KPC9ib2R5
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
global pasteLockUntil := 0
global pasteSending := false
global lastCaretX := 0
global lastCaretY := 0
global hasCaretPos := false
global panelVisible := false
global searchFocused := false
global linkMetaQueue := []
global linkMetaPausedUntil := 0
global wvBuilding := false
global uiPushPending := false
global uiPushTimerArmed := false
global liveFront := []   ; recently copied items not yet confirmed on disk (survive SetView)

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
; Explorer/Desktop already creates a file on Ctrl+V, and 蹇嵎閿? pastpng2dir also saves 鈥?
; a third/second save here made desktop Ctrl+V produce duplicate images.
;
; OnClipboardChange is registered AFTER InitClipsFromDisk (EnableClipboardWatch).
; Early register raced boot init 鈫?freeze/exit + history wipe on copy-right-after-start.

; 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
;  Panel hotkeys: while panel is open, keys go to clipboard
;  even if the editor still has focus (NoActivate popup)
; 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
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

; Unpinned: arrows / Enter / Esc hide (Esc always closes panel, even while searching)
#HotIf ClipPanelIsUp() && !uiPinned
Up::PanelKeyUp("")
Down::PanelKeyDown("")
Enter::PanelKeyEnter("")
Esc::EscHidePanel("")
~LButton::OnOutsideClick("")
~LAlt::EscHidePanel("")
~RAlt::EscHidePanel("")
#HotIf

; Pinned: arrows still navigate when panel is up
#HotIf ClipPanelIsUp() && uiPinned
Up::PanelKeyUp("")
Down::PanelKeyDown("")
Enter::PanelKeyEnter("")
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

; 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
;  Clipboard
; 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
ClipChanged(dataType) {
    global lastTxt, lastImg, clipIgnore, clipReady, diskScanBusy
    if clipIgnore || dataType = 0
        return
    ; Not ready yet (boot) 鈥?ignore; EnableClipboardWatch arms after InitClipsFromDisk
    if !clipReady {
        ClipLog("ClipChanged SKIP not-ready type=" dataType)
        return
    }
    ; Preload / heavy scan in progress 鈥?retry shortly (do not race disk)
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

    ; File drops first 鈥?skip ClipboardAll (can be huge / exotic shell formats 鈫?freeze)
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
        src := CaptureClipSrcIcon()
        item.srcIcon := src.icon
        item.srcExe := src.exe
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
            src := CaptureClipSrcIcon()
            item.srcIcon := src.icon
            item.srcExe := src.exe
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
        src := CaptureClipSrcIcon()
        item.srcIcon := src.icon
        item.srcExe := src.exe
        AddClipItem(item)
        AddLinksFromText(txt)
    }
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
        ; NEVER FileCopy/GDI+ here 鈥?thumbs are lazy via ensureFileImg
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
    ; Never call WebView sync from OnClipboardChange 鈥?it often drops the update.
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

; Only when user opens 閾炬帴 tab 鈥?never during Win+V open
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

; 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
;  Bridge
; 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
class ClipBridge {
    ; Defer out of sync WebView host call 鈥?sync paste from click re-enters and can paste twice
    paste(id) {
        RequestPaste(id)
    }
    pasteMany(ids) {
        RequestPasteMany(ids)
    }
    delete(id) {
        DeleteItem(id)
    }
    pin(id) {
        PinItem(id)
    }
    clear(tab := "all", scope := "today") {
        ClearTab(tab, scope)
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
        SetView(tab, query, today)
    }
    loadMore(*) {
        LoadMoreView()
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
            ; Never remember Start/Search as "previous app" 鈥?restoring it covers our panel
            prevActiveWin := ResolvePrevActiveWin(cur)
            ; OneNote: never probe caret (Gui/IME/Acc/UIA all risk Critical Error)
            if IsOneNoteApp() {
                lastCaretX := 0
                lastCaretY := 0
                hasCaretPos := false
            } else {
                GetCaretScreenPos(&cx, &cy, &found)
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

; Start/Search use a higher z-band 鈥?cannot cover them; dismiss the visible overlay only.
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
    global lastGoodActiveWin, guiWin, panelVisible
    try {
        cur := WinGetID("A")
        if !cur
            return
        if IsObject(guiWin) && cur = guiWin.Hwnd
            return
        if IsShellOverlayHwnd(cur) || IsScreenshotHelperHwnd(cur)
            return
        lastGoodActiveWin := cur
    }
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

KeepSearchDismissed(*) {
    global dismissSearchUntil, panelVisible
    if A_TickCount > dismissSearchUntil {
        SetTimer(KeepSearchDismissed, 0)
        return
    }
    ; Only when the large overlay is actually visible 鈥?process itself always exists
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
; We cannot draw above Start 鈥?prevent Start by delaying LWin until we know it's not Win+V.
HotkeyWinV(*) {
    RememberGoodActiveWin()
    ; Fallback only if Start somehow already visible
    if ShellOverlayIsShowing()
        DismissWindowsSearch()
    delay := IsOneNoteApp() ? -200 : -30
    SetTimer(TogglePanelDeferred, delay)
}

ShowPanel() {
    global guiWin, wv, wvCore, lastCaretX, lastCaretY, hasCaretPos, panelVisible, uiPinned, prevActiveWin, linkMetaPausedUntil, viewToday
    ClipLog("ShowPanel ENTER")

    ; Pause any background title fetching so Win+V stays responsive
    linkMetaPausedUntil := A_TickCount + 2000
    prevActiveWin := ResolvePrevActiveWin(prevActiveWin)

    ; OneNote: bottom-right only 鈥?never Acc/UIA/IME/Gui caret
    if !hasCaretPos && !IsOneNoteApp() {
        GetCaretScreenPos(&cx, &cy, &found)
        if found {
            lastCaretX := cx
            lastCaretY := cy
            hasCaretPos := true
        }
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

        lineGapBelow := 10   ; half of previous 20 鈥?panel under caret
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
    ; Restore previous app focus 鈥?never Start/Search (that re-covers our panel)
    prevActiveWin := ResolvePrevActiveWin(prevActiveWin)
    if prevActiveWin && !IsShellOverlayHwnd(prevActiveWin) {
        try DllCall("SetForegroundWindow", "Ptr", prevActiveWin)
    }
    if IsObject(wv) {
        try {
            wv.Fill()
            wv.IsVisible := true
            wv.NotifyParentWindowPositionChanged()
        }
    }
    if IsObject(wvCore) {
        ; Show first, push data after paint 鈥?avoids Win+V freeze on large clip JSON
        ; Drop any thin/poisoned viewCache (copy-before-open used to leave clips=1)
        try InvalidateViewCache()
        try wvCore.ExecuteScriptAsync("window.__onPanelShow && window.__onPanelShow()")
        ; SetView merges liveFront (fresh copies not yet on disk) so they don't flash-then-vanish
        SetTimer(() => (SetView("all", "", "0"), RequestUiPush()), -30)
        SetTimer(() => PushPinStateToUi(), -50)
    }
}

EscHidePanel(*) {
    global uiPinned
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

OnOutsideClick(*) {
    global guiWin, uiPinned, panelVisible
    if !panelVisible || uiPinned || !IsObject(guiWin)
        return
    try {
        CoordMode "Mouse", "Screen"
        MouseGetPos(&mx, &my)
        WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " guiWin.Hwnd)
        if (mx >= wx && mx <= wx + ww && my >= wy && my <= wy + wh)
            return
        HidePanel()
    }
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
            throw Error("鎵句笉鍒?WebView2Loader.dll:`n" dll)

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
        ; Prefer 8.3 short paths 鈥?spaces in "goland project" break WebView2 folder mapping.
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
            throw Error("鎵句笉鍒扮晫闈㈡枃浠?`n" HTML_FILE)

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
    global diskScanBusy
    ClipLog("WarmAllViews START")
    diskScanBusy := true
    try {
        InvalidateViewCache()
        PreloadAllViews("0")
        ClipLog("WarmAllViews Preload done 鈫?SetView all")
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
    global guiWin, prevActiveWin, searchFocused, uiPinned
    searchFocused := false
    ; Keep activatable while pinned so Ctrl+F still works without clicking UI
    if IsObject(guiWin) && !uiPinned {
        try guiWin.Opt("+E0x08000000")
    }
    if prevActiveWin && !uiPinned && !IsShellOverlayHwnd(prevActiveWin) {
        try DllCall("SetForegroundWindow", "Ptr", prevActiveWin)
    }
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

; Positioning strategy:
; - Light path: GuiThreadInfo / cache / IME
; - Heavy path: MSAA/UIA (other apps only)
; - OneNote: NEVER any caret probe 鈥?even Gui/IME can Critical Error; bottom-right only
; If none found 鈫?bottom-right
global cachedCaretX := 0
global cachedCaretY := 0
global cachedCaretTick := 0
global pendingCaretHwnd := 0

GetCaretScreenPos(&cx, &cy, &found := false) {
    cx := 0, cy := 0, found := false
    left := 0, top := 0, right := 0, bottom := 0

    ; Hard skip for OneNote 鈥?do not touch its process with caret APIs
    if IsOneNoteApp()
        return

    if GetCachedCaretPos(&x, &y) {
        cx := x, cy := y, found := true
        return
    }

    useHook := false
    try {
        pn := WinGetProcessName("A")
        if pn ~= "i)goland|idea|webstorm|pycharm|phpstorm|clion|rider|datagrip|rubymine"
            useHook := true
    }

    if GetCaretPosEx(&left, &top, &right, &bottom, useHook, false, false) {
        cx := left
        cy := bottom > top ? bottom : top + 18
        found := true
        CacheCaretPos(cx, cy)
        return
    }

    if GetCaretPosIME(&x, &y) {
        cx := x, cy := y, found := true
        CacheCaretPos(cx, cy)
        return
    }
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
    ; OneNote caret moves often; keep a short window so Win+V still hits last insert point
    maxAge := IsOneNoteApp() ? 4000 : 2000
    if (A_TickCount - cachedCaretTick) > maxAge
        return false
    if cachedCaretX = 0 && cachedCaretY = 0
        return false
    cx := cachedCaretX
    cy := cachedCaretY
    return true
}

; Background caret tracker disabled 鈥?LOCATIONCHANGE while scrolling made hosts
; auto-scroll an extra notch after the wheel stopped.
StartCaretWatcher() {
}
StopCaretWatcher() {
}

; Same as GetCaretPosEx getCaretPosFromGui 鈥?no COM
GetCaretPosFromGuiThread(&left, &top, &right, &bottom) {
    left := 0, top := 0, right := 0, bottom := 0
    x64 := A_PtrSize == 8
    guiThreadInfo := Buffer(x64 ? 72 : 48)
    NumPut("UInt", guiThreadInfo.Size, guiThreadInfo)
    if !DllCall("GetGUIThreadInfo", "UInt", 0, "Ptr", guiThreadInfo)
        return false
    hwndCaret := NumGet(guiThreadInfo, x64 ? 48 : 28, "Ptr")
    if !hwndCaret
        return false
    left := NumGet(guiThreadInfo, x64 ? 56 : 32, "Int")
    top := NumGet(guiThreadInfo, x64 ? 60 : 36, "Int")
    right := NumGet(guiThreadInfo, x64 ? 64 : 40, "Int")
    bottom := NumGet(guiThreadInfo, x64 ? 68 : 44, "Int")
    if (right - left) < 1 && (bottom - top) < 1
        return false
    pt := Buffer(8, 0)
    NumPut("Int", left, pt, 0)
    NumPut("Int", bottom, pt, 4)
    DllCall("ClientToScreen", "Ptr", hwndCaret, "Ptr", pt)
    left := NumGet(pt, 0, "Int")
    bottom := NumGet(pt, 4, "Int")
    top := bottom - Max(bottom - top, 1)
    right := left + 1
    return true
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
    ; WM_IME_REQUEST=0x0288, IMR_QUERYCHARPOSITION=6 鈥?never block forever
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
    global wvCore, clips, viewTotal
    if !IsObject(wvCore)
        return
    payload := "{"
    payload .= '"append":' (append ? "true" : "false") ","
    payload .= '"total":' Integer(viewTotal) ","
    payload .= '"items":' ClipsToJson(append)
    payload .= "}"
    try wvCore.ExecuteScriptAsync("window.__updateClips && window.__updateClips(" payload ");window.__loadMoreDone&&window.__loadMoreDone()")
    ; Virtual-host thumbs are unreliable (path spaces / WV2); inject data-URLs from AHK
    SetTimer(PushStoreThumbs.Bind(append), -60)
}

; Coalesce UI refreshes 鈥?safe to call from OnClipboardChange / disk jobs
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
    global uiPushPending, uiPushTimerArmed, wvCore, panelVisible, clips
    uiPushTimerArmed := false
    if !uiPushPending
        return
    uiPushPending := false
    if !IsObject(wvCore)
        return
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

; Small JPEG list preview (cached next to original) 鈥?keeps inject payload small
ListThumbDataUrl(name) {
    global STORE_DIR
    name := String(name)
    if name = ""
        return ""
    src := STORE_DIR "\" name
    if !FileExist(src)
        return ""
    ; Create/refresh th_*.jpg when missing (safe outside Critical 鈥?was hung only under Critical)
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
    global clips, PAGE_SIZE, lastAppendCount
    start := 1
    if append && lastAppendCount > 0
        start := Max(1, clips.Length - lastAppendCount + 1)
    out := "["
    first := true
    loop clips.Length {
        i := A_Index
        if i < start
            continue
        c := clips[i]
        if !first
            out .= ","
        first := false
        imgFile := c.HasProp("imgFile") ? c.imgFile : ""
        preview := c.HasProp("preview") ? String(c.preview) : ""
        ; List payload must stay small 鈥?full text body is loaded only on paste
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
    global prevActiveWin, clipIgnore
    item := ResolveClip(uid)
    if !IsObject(item)
        return

    ; Hide first 鈥?never keep UI up while disk/JSON work runs
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
        if prevActiveWin {
            DllCall("SetForegroundWindow", "Ptr", prevActiveWin)
            Sleep 15
        }
        TriggerPasteKey()
    } finally {
        SetTimer(() => (clipIgnore := false), -400)
    }
}

PasteMany(idsStr) {
    global prevActiveWin, clipIgnore
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
        HidePanel()
        clipIgnore := true
        try {
            if !SetClipboardFiles(paths)
                return
            MarkItemsPasted(uids)
            if prevActiveWin {
                DllCall("SetForegroundWindow", "Ptr", prevActiveWin)
                Sleep 30
            }
            TriggerPasteKey()
        } finally {
            SetTimer(() => (clipIgnore := false), -500)
        }
        return
    }

    HidePanel()
    clipIgnore := true
    pastedIds := []
    try {
        if prevActiveWin {
            DllCall("SetForegroundWindow", "Ptr", prevActiveWin)
            Sleep 20
        }
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

; "1" / "0" 鈥?simple return for WebView hostObjects (avoids JSON parse issues)
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
    ; Dedupe identical paths (guards against same temp name twice 鈫?one image pasted twice)
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

; Bridge entry: leave WebView sync stack + debounce (click鈫抙ost.call re-entrancy = double paste)
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
; Explorer/Desktop already pastes HDROP/bitmap once 鈥?calling PastePngToDir here duplicated files (2鈫?).
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
    ; Optimistic UI: remove from memory first, disk later
    imgFile := ""
    itemType := ""
    for c in clips {
        if c.uid = uid {
            if c.HasProp("imgFile")
                imgFile := c.imgFile
            itemType := c.type
            ; Allow re-copy of the same content after delete (ClipChanged dedupes via lastTxt/lastImg)
            if itemType = "text" || itemType = "link"
                lastTxt := ""
            else if itemType = "image"
                lastImg := ""
            break
        }
    }
    if itemType = "" {
        ; Not in current list 鈥?still clear dedupe if we can resolve it
        it := ResolveClip(uid)
        if IsObject(it) {
            itemType := it.type
            if it.HasProp("imgFile")
                imgFile := it.imgFile
            if itemType = "text" || itemType = "link"
                lastTxt := ""
            else if itemType = "image"
                lastImg := ""
        }
    }
    MemoryRemoveUid(uid)
    if IsObject(wvCore)
        PushClips(false)
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
        ; Not in current list 鈥?still flip on disk/cache via resolve
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
    ; Optimistic memory update 鈥?disk write is async (was blocking paste for seconds)
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
        ; Merge is a favorites feature 鈥?keep pinned
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
    global viewTab, viewQuery, viewToday, lastTxt, lastImg
    tab := StrLower(Trim(String(tab)))
    scope := StrLower(Trim(String(scope)))
    clearAllDates := (scope = "all")
    today := FormatTime(, "yyyy-MM-dd")
    DiskClearTab(tab, clearAllDates, today)
    ; Reset clipboard dedupe so cleared content can be captured again
    if tab = "all" || tab = "text" || tab = "link"
        lastTxt := ""
    if tab = "all" || tab = "image"
        lastImg := ""
    SetView(viewTab, viewQuery, viewToday ? "1" : "0")
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

; 8.3 short path 鈥?WebView2 virtual host mapping fails on folders with spaces
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

; Capture foreground (or last non-panel / non-snip) process icon
CaptureClipSrcIcon() {
    global guiWin, prevActiveWin, lastGoodActiveWin
    hwnd := 0
    try hwnd := WinExist("A")
    if IsObject(guiWin) && guiWin.Hwnd && hwnd = guiWin.Hwnd
        hwnd := prevActiveWin ? prevActiveWin : lastGoodActiveWin
    ; Win+Shift+S / 鎴浘宸ュ叿甯镐細鎶㈠墠鍙?鈥?鐢ㄦ埅鍥惧墠鐨勭湡瀹炵獥鍙?
    if IsScreenshotHelperHwnd(hwnd) || IsShellOverlayHwnd(hwnd)
        hwnd := lastGoodActiveWin ? lastGoodActiveWin : prevActiveWin
    if !hwnd
        return { icon: "", exe: "" }
    exePath := ""
    exeName := ""
    try {
        exePath := WinGetProcessPath("ahk_id " hwnd)
        exeName := WinGetProcessName("ahk_id " hwnd)
    }
    if IsScreenshotHelperExe(exeName) {
        hwnd := lastGoodActiveWin ? lastGoodActiveWin : prevActiveWin
        if !hwnd
            return { icon: "", exe: "" }
        try {
            exePath := WinGetProcessPath("ahk_id " hwnd)
            exeName := WinGetProcessName("ahk_id " hwnd)
        }
    }
    if exePath = "" || !FileExist(exePath)
        return { icon: "", exe: exeName }
    return { icon: SaveExeIconToStore(exePath), exe: exeName }
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
        ClipLog("EnsureFileImageInStore FileCopy 鈫?" name)
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
    ; Soft path only 鈥?never call GDI+ here (native hang/kill under disk jobs)
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
            ClipLog("EnsureFileClipThumb store empty 鈥?skip")
            return
        }
        item.imgFile := name
        ; Dimensions optional 鈥?GdipCreateBitmapFromFile hung/killed process; skip
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
; NDJSON page store (inlined 鈥?was ahk\clip_v1\ndjson_pages.ahk)
; each shard holds at most PAGE_SIZE records (newest pages first)
; 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
; NDJSON page store: each shard file holds at most PAGE_SIZE records (newest pages first).
; Query/mutate only load one shard at a time 鈥?peak memory stays bounded.

ItemToJsonLine(c) {
    imgFile := c.HasProp("imgFile") ? c.imgFile : ""
    dataFile := c.HasProp("dataFile") ? c.dataFile : ""
    preview := c.HasProp("preview") ? c.preview : ""
    if c.type = "image" {
        preview := ""
        data := ""
        dataFile := ""
    } else if dataFile != "" {
        ; Large body lives in clips_payloads 鈥?keep NDJSON line small/reliable
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
            ; List/query path: keep preview only 鈥?full body loaded on paste/resolve
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
    ; List/query path: regex extract 鈥?avoid HTMLFile COM JSON (very slow per line)
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
    if item.type = "image" {
        item.data := ""
        if item.imgFile = ""
            return ""
    } else if item.dataFile != "" {
        ; Large body on disk 鈥?load only when pasting
        item.data := ""
        if item.type = "file"
            item._looksImage := PreviewLooksLikeImagePath(item.preview)
    } else {
        ; Inline body (small) kept in memory for instant paste
        item.data := JsonFieldStr(line, "data")
        if item.preview = "" && (item.type = "text" || item.type = "link" || item.type = "file")
            item.preview := SubStr(item.data, 1, 500)
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
    ; Only check first path line 鈥?enough for list bucketing
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
        ; Do NOT use HTMLFile JSON array parse 鈥?it often returns incomplete pages and
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
    ; Always re-attach orphan shards before writing 鈥?never shrink pages to one new file
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

; Write via tmp + MoveFileEx(REPLACE) 鈥?never delete the live file first (crash = data loss)
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
        ; Do NOT auto-rewrite on dirty/partial parse 鈥?that wiped shards when any line failed
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
    ; No Critical here 鈥?disk jobs are already serialized by DrainDiskJobs.
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
        ; Prepend raw line 鈥?never parse+rewrite (one bad line used to wipe the whole shard)
        ClipLog("DiskInsertFront PrependPageLine " pages[1])
        if PrependPageLine(pages[1], ItemToJsonLine(item)) {
            m["pages"] := pages
            SaveManifest(m)
            ClipLog("DiskInsertFront prepend OK")
            return true
        }
        ; Prepend failed: new shard only 鈥?keep existing pages intact
        name := NewPageName(m)
        ClipLog("DiskInsertFront prepend FAIL 鈫?newPage=" name)
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
    for name in pages {
        if IsObject(removed) {
            newPages.Push(name)
            continue
        }
        items := ReadPageFile(name)
        kept := []
        changed := false
        for c in items {
            if c.uid = uid {
                removed := c
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
    ; Patch NDJSON line in place 鈥?avoid full parse/rewrite (async race broke 鏀惰棌)
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
    ; Patch NDJSON lines in place 鈥?do NOT full-parse / load payloads (that froze paste)
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
    for name in m["pages"] {
        items := ReadPageFile(name)
        kept := []
        for c in items {
            drop := false
            if ItemMatchesClearTab(c, tab) {
                drop := true
                if tab != "pinned" && c.HasOwnProp("pinned") && c.pinned
                    drop := false
                if drop && !clearAllDates {
                    t := c.HasOwnProp("time") ? String(c.time) : ""
                    if SubStr(t, 1, 10) != today
                        drop := false
                }
            }
            if drop
                DeleteStoredImage(c)
            else
                kept.Push(c)
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
        qLower := StrLower(q)
        if type = "image" {
            ; Images have no text body 鈥?allow match via favorite title only
            if favTitle = "" || !InStr(StrLower(favTitle), qLower)
                return false
        } else {
            hay := StrLower(String(c.preview || "") " " String(c.data || "") " " String(c.HasProp("linkTitle") ? c.linkTitle : "") " " favTitle)
            if !InStr(hay, qLower)
                return false
        }
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
    if q != "" {
        ; Search: collect all hits, expand fav-groups, then page
        all := []
        m := LoadManifest()
        for name in m["pages"] {
            for c in ReadPageFile(name, true) {
                if ItemMatchesView(c, tab, q, todayOnly)
                    all.Push(c)
            }
        }
        ExpandFavGroupHits(all, tab, todayOnly)
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
        }
    }
    return { items: items, total: total }
}

; 鏀惰棌: newest pinTime first (not create time / disk order)
QueryPinnedDiskPage(query, todayOnly, offset, limit) {
    all := []
    m := LoadManifest()
    for name in m["pages"] {
        for c in ReadPageFile(name, true) {
            if ItemMatchesView(c, "pinned", query, todayOnly)
                all.Push(c)
        }
    }
    if Trim(String(query)) != ""
        ExpandFavGroupHits(all, "pinned", todayOnly)
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
    ; Inline record with empty data (shouldn't happen after fast parse) 鈥?reload from disk
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
    ; Do NOT CacheCurrentView() here 鈥?that overwrote a full disk page with the
    ; in-memory clips window (often 1 item after copy-before-open) and hid history.
}

; Keep freshly copied items across InvalidateViewCache / SetView(disk) races
LiveFrontAdd(item) {
    global liveFront
    if !IsObject(item) || !item.HasProp("uid")
        return
    LiveFrontRemoveUid(item.uid)
    liveFront.InsertAt(1, item)
    ; Bound memory 鈥?only need the newest few until disk catches up
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
    ; Search: also bring live siblings of any favGroup already in the result
    if Trim(String(viewQuery)) != "" {
        gids := Map()
        for c in clips {
            g := (IsObject(c) && c.HasProp("favGroup") ? Trim(String(c.favGroup)) : "")
            if g != ""
                gids[g] := true
        }
        for c in add {
            g := (c.HasProp("favGroup") ? Trim(String(c.favGroup)) : "")
            if g != ""
                gids[g] := true
        }
        if gids.Count {
            for c in liveFront {
                if !IsObject(c) || !c.HasProp("uid")
                    continue
                uid := Integer(c.uid)
                if have.Has(uid)
                    continue
                g := (c.HasProp("favGroup") ? Trim(String(c.favGroup)) : "")
                if g = "" || !gids.Has(g)
                    continue
                if !ItemMatchesView(c, viewTab, "", viewToday)
                    continue
                add.Push(c)
                have[uid] := true
            }
        }
    }
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
        ; Still running 鈥?retry soon so queued jobs are not stuck until next copy
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
    ; No Critical here 鈥?GDI+/FileCopy under Critical hung then killed the process
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

; Large text/link 鈫?external payload file (NDJSON line stays small so reload won't drop it)
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
    global viewCache, viewToday, VIEW_PAGE_SIZE
    Critical "On"
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
                        ; 鏀惰棌: collect all then sort by pinTime (other tabs: disk order, first N)
                        if tab = "pinned" || b.items.Length < VIEW_PAGE_SIZE
                            b.items.Push(c)
                        b.total += 1
                    }
                    ; Show 鍏ㄩ儴 as soon as first page is full 鈥?don't wait for whole scan
                    if !allShown && buckets.Has("all") && buckets["all"].items.Length >= VIEW_PAGE_SIZE {
                        b := buckets["all"]
                        viewCache[b.key] := { items: b.items.Clone(), total: Max(b.total, VIEW_PAGE_SIZE) }
                        SetView("all", "", todayFlag ? "1" : "0")
                        allShown := true
                    }
                    if Mod(++n, 32) = 0
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
    } finally {
        Critical "Off"
    }
}

; Kept for callers that still name the old helper
PreloadNonLinkViews(today := "") {
    PreloadAllViews(today)
}

SetView(tab := "all", query := "", today := "0") {
    global clips, viewTab, viewQuery, viewToday, viewTotal, VIEW_PAGE_SIZE, lastAppendCount, wvCore, viewCache
    viewTab := StrLower(Trim(String(tab)))
    if viewTab = ""
        viewTab := "all"
    viewQuery := String(query)
    viewToday := (String(today) = "1" || String(today) = "true")
    lastAppendCount := 0
    key := ViewCacheKey(viewTab, viewQuery, viewToday)
    if viewCache.Has(key) {
        entry := viewCache[key]
        ; Reject poisoned thin cache (e.g. 1 copied item claimed as whole view)
        thin := !IsObject(entry) || !entry.HasProp("items")
            || (entry.items.Length < VIEW_PAGE_SIZE && entry.total <= entry.items.Length && entry.items.Length < 5)
        if !thin {
            clips := []
            for c in entry.items
                clips.Push(c)
            viewTotal := entry.total
            MergeLiveFrontIntoClips()
            ClipLog("SetView cache hit tab=" viewTab " n=" clips.Length " total=" viewTotal)
            if IsObject(wvCore)
                PushClips(false)
            return
        }
        ClipLog("SetView drop thin cache tab=" viewTab " n=" entry.items.Length " total=" entry.total)
        viewCache.Delete(key)
    }
    page := QueryDiskPage(viewTab, viewQuery, viewToday, 0, VIEW_PAGE_SIZE)
    clips := page.items
    viewTotal := page.total
    MergeLiveFrontIntoClips()
    ClipLog("SetView disk tab=" viewTab " n=" clips.Length " total=" viewTotal)
    CacheCurrentView()
    if IsObject(wvCore)
        PushClips(false)
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

; One-time migrate clips.json 鈫?NDJSON shards of PAGE_SIZE
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
    ClipLog("OnExit reason=" exitReason " code=" exitCode " 鈥?flushing disk")
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

; Clipboard watch ONLY after disk init 鈥?early OnClipboardChange caused boot-copy crash
EnableClipboardWatch()
ClipLog("EnableClipboardWatch scheduled")

; Register Win+V before BuildGui (WebView2 init must not block hotkey setup)
try RegWrite(0, "REG_DWORD", "HKCU\Software\Microsoft\Clipboard", "EnableClipboardHistory")
A_MenuMaskKey := "vkE8"

; 鈹€鈹€ Win key gate 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
; Windows clipboard sits in a higher shell z-band; our GUI cannot cover Start/Search.
; Swallow Win on keydown and NEVER auto-forward on a timer (that was reopening Search).
; - Win+V  鈫?our panel (Win never reaches OS)
; - Win+鍏跺畠 鈫?forward Win then the key
; - 鍗曞嚮 Win 鈫?on release, open Start
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
; Quick Win+other 鈥?still reach the OS
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

StartCaretWatcher()
SetTimer(RememberGoodActiveWin, 400)
ClipLog("=== SCRIPT BOOT auto-execute END 鈥?waiting for clipReady ===")

; WebView2 is created lazily on first Win+V 鈥?avoid spawning Edge at script start

; 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
;  Init: create ahk\clip_v1 dirs and write HTML
; 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
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
    ClipLog("clipReady=TRUE 鈥?accepting clipboard now")
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

; 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
;  Ctrl+V: save clipboard image(s) into the active folder (not ahk\clip_v1)
; 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
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
            ; Skip directories 鈥?never copy/create folder trees
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
