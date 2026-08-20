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
PCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9InpoLUNOIj4KPGhlYWQ+CiAgICA8bWV0YSBjaGFy
c2V0PSJVVEYtOCI+CiAgICA8dGl0bGU+5Ymq6LS05p2/PC90aXRsZT4KICAgIDxzdHlsZT4KICAg
ICAgICA6cm9vdCB7CiAgICAgICAgICAgIC0tYmc6ICAgICAjZWVmMWY2OwogICAgICAgICAgICAt
LWFjYzogICAgIzViNzNlODsKICAgICAgICAgICAgLS10eHQ6ICAgICMyYzJlMzY7CiAgICAgICAg
ICAgIC0tdHh0MjogICAjNmI3MDgwOwogICAgICAgICAgICAtLXR4dDM6ICAgIzlhYTBiMDsKICAg
ICAgICAgICAgLS1jYXJkOiAgICNmZmZmZmY7CiAgICAgICAgICAgIC0tY2FyZC1oOiAjZjhmOWZj
OwogICAgICAgICAgICAtLXI6ICAgICAgNHB4OwogICAgICAgICAgICAtLXRyOiAgICAgMC4xMnMg
ZWFzZTsKICAgICAgICB9CiAgICAgICAgKiwgKjo6YmVmb3JlLCAqOjphZnRlciB7IGJveC1zaXpp
bmc6IGJvcmRlci1ib3g7IG1hcmdpbjogMDsgcGFkZGluZzogMDsgfQogICAgICAgIGh0bWwsIGJv
ZHkgewogICAgICAgICAgICB3aWR0aDogMTAwJTsgaGVpZ2h0OiAxMDAlOyBvdmVyZmxvdzogaGlk
ZGVuOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiB2YXIoLS1iZyk7IGNvbG9yOiB2YXIoLS10eHQp
OwogICAgICAgICAgICBmb250OiAxMnB4LzEuNDUgJ1NlZ29lIFVJJywnTWljcm9zb2Z0IFlhSGVp
IFVJJyxzeXN0ZW0tdWksc2Fucy1zZXJpZjsKICAgICAgICAgICAgdXNlci1zZWxlY3Q6IG5vbmU7
CiAgICAgICAgfQogICAgICAgIDo6LXdlYmtpdC1zY3JvbGxiYXIgeyB3aWR0aDogNHB4OyB9CiAg
ICAgICAgOjotd2Via2l0LXNjcm9sbGJhci10aHVtYiB7IGJhY2tncm91bmQ6ICNkMGQzZGM7IGJv
cmRlci1yYWRpdXM6IDJweDsgfQoKICAgICAgICAjYXBwIHsKICAgICAgICAgICAgaGVpZ2h0OiAx
MDAlOyBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOwogICAgICAgICAgICBi
YWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGllbnQoMTgwZGVnLCAjZjdmOWZjIDAlLCAjZWVmMWY2IDEw
MCUpOwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IGRyYWc7IGFwcC1yZWdpb246IGRy
YWc7CiAgICAgICAgICAgIHBvc2l0aW9uOiByZWxhdGl2ZTsKICAgICAgICAgICAgb3ZlcmZsb3c6
IGhpZGRlbjsKICAgICAgICB9CgogICAgICAgIC8qIOKUgOKUgCBSb3cgMSDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAgKi8KICAgICAg
ICAjaGRyIHsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsg
ZmxleC1zaHJpbms6IDA7CiAgICAgICAgICAgIHBhZGRpbmc6IDVweCA2cHggNXB4IDhweDsgZ2Fw
OiA0cHg7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNmMmY0Zjk7CiAgICAgICAgfQogICAgICAg
ICNoZWFydCB7IGZsZXgtc2hyaW5rOiAwOyBsaW5lLWhlaWdodDogMTsgZGlzcGxheTpmbGV4OyBh
bGlnbi1pdGVtczpjZW50ZXI7IH0KICAgICAgICAjaGVhcnQgc3ZnIHsgd2lkdGg6MTdweDsgaGVp
Z2h0OjE3cHg7IGNvbG9yOiB2YXIoLS10eHQyKTsgfQogICAgICAgICNoZHItZ3JvdyB7IGZsZXg6
IDE7IG1pbi13aWR0aDogOHB4OyB9CgogICAgICAgIC8qIFNlYXJjaDogb3ZlcmxheSBleHBhbmQg
KHRyYW5zZm9ybS9vcGFjaXR5IG9ubHkg4oCUIG5vIHdpZHRoIGxheW91dCB0aHJhc2gpICovCiAg
ICAgICAgI3NlYXJjaC13cmFwIHsKICAgICAgICAgICAgZmxleDogMCAwIDI4cHg7CiAgICAgICAg
ICAgIHdpZHRoOiAyOHB4OwogICAgICAgICAgICBoZWlnaHQ6IDI4cHg7CiAgICAgICAgICAgIHBv
c2l0aW9uOiByZWxhdGl2ZTsKICAgICAgICAgICAgei1pbmRleDogNjsKICAgICAgICAgICAgLXdl
YmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgIH0K
ICAgICAgICAjYnRuLXNlYXJjaCB7CiAgICAgICAgICAgIHBvc2l0aW9uOiBhYnNvbHV0ZTsgcmln
aHQ6IDA7IHRvcDogMDsKICAgICAgICAgICAgd2lkdGg6IDI4cHg7IGhlaWdodDogMjhweDsKICAg
ICAgICAgICAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250
ZW50OiBjZW50ZXI7CiAgICAgICAgICAgIGJvcmRlcjogbm9uZTsgYmFja2dyb3VuZDogbm9uZTsg
Y3Vyc29yOiBwb2ludGVyOwogICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0Myk7IGJvcmRlci1y
YWRpdXM6IHZhcigtLXIpOwogICAgICAgICAgICB6LWluZGV4OiAyOwogICAgICAgICAgICB0cmFu
c2l0aW9uOiBjb2xvciAwLjE1cyBlYXNlLCBiYWNrZ3JvdW5kIDAuMTVzIGVhc2UsIG9wYWNpdHkg
MC4xNXMgZWFzZTsKICAgICAgICB9CiAgICAgICAgI2J0bi1zZWFyY2g6aG92ZXIgeyBjb2xvcjog
dmFyKC0tYWNjKTsgYmFja2dyb3VuZDogcmdiYSg5MSwxMTUsMjMyLC4xKTsgfQogICAgICAgICNi
dG4tc2VhcmNoIHN2ZyB7IHdpZHRoOiAxNXB4OyBoZWlnaHQ6IDE1cHg7IGRpc3BsYXk6IGJsb2Nr
OyB9CiAgICAgICAgI3NlYXJjaC13cmFwLm9wZW4gI2J0bi1zZWFyY2ggewogICAgICAgICAgICBv
cGFjaXR5OiAwOwogICAgICAgICAgICBwb2ludGVyLWV2ZW50czogbm9uZTsKICAgICAgICB9Cgog
ICAgICAgICNzZWFyY2gtYm94IHsKICAgICAgICAgICAgdHJhbnNmb3JtLW9yaWdpbjogcmlnaHQg
Y2VudGVyOwogICAgICAgICAgICBwb3NpdGlvbjogYWJzb2x1dGU7CiAgICAgICAgICAgIHJpZ2h0
OiAwOwogICAgICAgICAgICB0b3A6IDA7CiAgICAgICAgICAgIHdpZHRoOiAxOTZweDsKICAgICAg
ICAgICAgaGVpZ2h0OiAyOHB4OwogICAgICAgICAgICBib3gtc2l6aW5nOiBib3JkZXItYm94Owog
ICAgICAgICAgICBwYWRkaW5nOiAwIDJweCAwIDJweDsKICAgICAgICAgICAgYmFja2dyb3VuZDog
dHJhbnNwYXJlbnQ7CiAgICAgICAgICAgIGJvcmRlcjogbm9uZTsKICAgICAgICAgICAgYm9yZGVy
LXJhZGl1czogMDsKICAgICAgICAgICAgb3BhY2l0eTogMDsKICAgICAgICAgICAgdHJhbnNmb3Jt
OiB0cmFuc2xhdGUzZCg4cHgsIDAsIDApIHNjYWxlKDAuOTg1KTsKICAgICAgICAgICAgcG9pbnRl
ci1ldmVudHM6IG5vbmU7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7CiAgICAgICAgICAgIGFs
aWduLWl0ZW1zOiBjZW50ZXI7CiAgICAgICAgICAgIGdhcDogNHB4OwogICAgICAgICAgICB3aWxs
LWNoYW5nZTogdHJhbnNmb3JtLCBvcGFjaXR5OwogICAgICAgICAgICBiYWNrZmFjZS12aXNpYmls
aXR5OiBoaWRkZW47CiAgICAgICAgICAgIHRyYW5zaXRpb246IG9wYWNpdHkgMC4xOHMgZWFzZSwg
dHJhbnNmb3JtIDAuMjRzIGN1YmljLWJlemllcigwLjE2LCAxLCAwLjMsIDEpOwogICAgICAgIH0K
ICAgICAgICAjc2VhcmNoLXdyYXAub3BlbiAjc2VhcmNoLWJveCB7CiAgICAgICAgICAgIHRyYW5z
Zm9ybS1vcmlnaW46IHJpZ2h0IGNlbnRlcjsKICAgICAgICAgICAgdHJhbnNmb3JtLW9yaWdpbjog
cmlnaHQgY2VudGVyOwogICAgICAgICAgICBvcGFjaXR5OiAxOwogICAgICAgICAgICB0cmFuc2Zv
cm06IHRyYW5zbGF0ZTNkKDAsIDAsIDApOwogICAgICAgICAgICBwb2ludGVyLWV2ZW50czogYXV0
bzsKICAgICAgICB9CgogICAgICAgICNzZWFyY2ggewogICAgICAgICAgICBmbGV4OiAxOyBtaW4t
d2lkdGg6IDA7IGhlaWdodDogMjhweDsgYm9yZGVyOiBub25lOwogICAgICAgICAgICBib3JkZXIt
Ym90dG9tOiAxcHggc29saWQgdHJhbnNwYXJlbnQ7CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6
IDA7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OyBjb2xvcjogdmFyKC0tdHh0KTsgZm9udC1zaXpl
OiAxMnB4OwogICAgICAgICAgICBwYWRkaW5nOiAwIDIycHggMCAycHg7IG91dGxpbmU6IG5vbmU7
CiAgICAgICAgICAgIHRyYW5zaXRpb246IGJvcmRlci1ib3R0b20tY29sb3IgMC4xOHMgZWFzZTsK
ICAgICAgICB9CiAgICAgICAgI3NlYXJjaC13cmFwLm9wZW4gI3NlYXJjaCB7CiAgICAgICAgICAg
IGJvcmRlci1ib3R0b20tY29sb3I6ICNjNWNhZDY7CiAgICAgICAgfQogICAgICAgICNzZWFyY2gt
d3JhcC5vcGVuICNzZWFyY2g6Zm9jdXMgewogICAgICAgICAgICBib3JkZXItYm90dG9tLWNvbG9y
OiB2YXIoLS1hY2MpOwogICAgICAgIH0KICAgICAgICBtYXJrLnEtaGwgewogICAgICAgICAgICBi
YWNrZ3JvdW5kOiByZ2JhKDI1NSwgMTk2LCAwLCAuNDIpOwogICAgICAgICAgICBjb2xvcjogaW5o
ZXJpdDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogMnB4OwogICAgICAgICAgICBwYWRkaW5n
OiAwIDFweDsKICAgICAgICAgICAgZGlzcGxheTogaW5saW5lOwogICAgICAgICAgICBib3gtZGVj
b3JhdGlvbi1icmVhazogY2xvbmU7CiAgICAgICAgICAgIC13ZWJraXQtYm94LWRlY29yYXRpb24t
YnJlYWs6IGNsb25lOwogICAgICAgIH0KICAgICAgICAvKiBtYXJrIGJyZWFrcyAtd2Via2l0LWxp
bmUtY2xhbXA7IGtlZXAgZm9sZCB2aWEgbWF4LWhlaWdodCB3aGlsZSBzZWFyY2hpbmcgKi8KICAg
ICAgICAuaS1wcmV2Lmhhcy1obCwgLmktbmFtZS5oYXMtaGwsIC5tZy1ib2R5Lmhhcy1obCwKICAg
ICAgICAuaS1saW5rLXRpdGxlLmhhcy1obCwgLmktbGluay11cmwuaGFzLWhsLCAuaS1mYXYtdGl0
bGUuaGFzLWhsIHsKICAgICAgICAgICAgZGlzcGxheTogYmxvY2s7CiAgICAgICAgICAgIC13ZWJr
aXQtbGluZS1jbGFtcDogdW5zZXQ7CiAgICAgICAgICAgIG92ZXJmbG93OiBoaWRkZW47CiAgICAg
ICAgfQogICAgICAgIC5pLXByZXYuaGFzLWhsLCAubWctYm9keS5oYXMtaGwgeyBtYXgtaGVpZ2h0
OiBjYWxjKDEuNDVlbSAqIDUpOyB9CiAgICAgICAgLmktbmFtZS5oYXMtaGwgeyBtYXgtaGVpZ2h0
OiBjYWxjKDEuNDVlbSAqIDIpOyB9CiAgICAgICAgLmktbGluay11cmwuaGFzLWhsIHsgbWF4LWhl
aWdodDogY2FsYygxLjQ1ZW0gKiAzKTsgfQogICAgICAgIC5pLXByZXYuaGFzLWhsLmV4cGFuZGVk
LCAuaS1uYW1lLmhhcy1obC5leHBhbmRlZCwKICAgICAgICAubWctYm9keS5oYXMtaGwuZXhwYW5k
ZWQsIC5pLWxpbmstdXJsLmhhcy1obC5leHBhbmRlZCB7CiAgICAgICAgICAgIG1heC1oZWlnaHQ6
IG5vbmU7CiAgICAgICAgICAgIG92ZXJmbG93OiB2aXNpYmxlOwogICAgICAgIH0KICAgICAgICAu
aS1leHBhbmQtYnRuLCAuaS1tZXRhIHsgdXNlci1zZWxlY3Q6IG5vbmU7IH0KICAgICAgICAjc2Vh
cmNoOjpwbGFjZWhvbGRlciB7IGNvbG9yOiB2YXIoLS10eHQzKTsgfQogICAgICAgICNzZWFyY2gt
Y2xyIHsKICAgICAgICAgICAgcG9zaXRpb246IGFic29sdXRlOyByaWdodDogNHB4OyB0b3A6IDUw
JTsgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKC01MCUpOwogICAgICAgICAgICBib3JkZXI6IG5vbmU7
IGJhY2tncm91bmQ6IG5vbmU7IGNvbG9yOiB2YXIoLS10eHQzKTsgY3Vyc29yOiBwb2ludGVyOwog
ICAgICAgICAgICBmb250LXNpemU6IDExcHg7IGRpc3BsYXk6IG5vbmU7IHBhZGRpbmc6IDJweDsK
ICAgICAgICAgICAgb3BhY2l0eTogMC44NTsKICAgICAgICAgICAgdHJhbnNpdGlvbjogY29sb3Ig
MC4xMnMgZWFzZSwgb3BhY2l0eSAwLjEycyBlYXNlOwogICAgICAgICAgICAtd2Via2l0LWFwcC1y
ZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgfQogICAgICAgICNz
ZWFyY2gtY2xyOmhvdmVyIHsgY29sb3I6IHZhcigtLWFjYyk7IG9wYWNpdHk6IDE7IH0KCiAgICAg
ICAgI2J0bi10b2RheSB7CiAgICAgICAgICAgIGRpc3BsYXk6IG5vbmU7CiAgICAgICAgICAgIGhl
aWdodDogMThweDsgcGFkZGluZzogMCA3cHg7IGZsZXgtc2hyaW5rOiAwOwogICAgICAgICAgICBh
bGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAgICAgICAgICAg
Ym9yZGVyOiAxcHggc29saWQgcmdiYSg5MSwxMTUsMjMyLC4yMik7IGJhY2tncm91bmQ6IHJnYmEo
OTEsMTE1LDIzMiwuMTApOwogICAgICAgICAgICBjb2xvcjogIzZiODJlODsgYm9yZGVyLXJhZGl1
czogOTk5cHg7IGZvbnQtc2l6ZTogOXB4OyBmb250LXdlaWdodDogNjAwOwogICAgICAgICAgICBs
aW5lLWhlaWdodDogMTsgd2hpdGUtc3BhY2U6IG5vd3JhcDsgY3Vyc29yOiBwb2ludGVyOwogICAg
ICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7
CiAgICAgICAgICAgIHRyYW5zaXRpb246IGNvbG9yIHZhcigtLXRyKSwgYmFja2dyb3VuZCB2YXIo
LS10ciksIGJvcmRlci1jb2xvciB2YXIoLS10ciksIG9wYWNpdHkgdmFyKC0tdHIpOwogICAgICAg
IH0KICAgICAgICAjc2VhcmNoLXdyYXAub3BlbiAjYnRuLXRvZGF5IHsgZGlzcGxheTogaW5saW5l
LWZsZXg7IH0KICAgICAgICAjYnRuLXRvZGF5OmhvdmVyIHsgY29sb3I6ICM0YTYyZDQ7IGJhY2tn
cm91bmQ6IHJnYmEoOTEsMTE1LDIzMiwuMTYpOyB9CiAgICAgICAgI2J0bi10b2RheS5vbiB7CiAg
ICAgICAgICAgIGNvbG9yOiAjNWI3M2U4OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDkx
LDExNSwyMzIsLjE2KTsKICAgICAgICAgICAgYm9yZGVyLWNvbG9yOiByZ2JhKDkxLDExNSwyMzIs
LjMyKTsKICAgICAgICB9CiAgICAgICAgI2J0bi10b2RheTpub3QoLm9uKSB7CiAgICAgICAgICAg
IGNvbG9yOiB2YXIoLS10eHQzKTsKICAgICAgICAgICAgYmFja2dyb3VuZDogcmdiYSgwLDAsMCwu
MDQpOwogICAgICAgICAgICBib3JkZXItY29sb3I6IHJnYmEoMCwwLDAsLjA2KTsKICAgICAgICB9
CgogICAgICAgICNidG4tcGluIHsKICAgICAgICAgICAgd2lkdGg6IDI4cHg7IGhlaWdodDogMjhw
eDsgZmxleC1zaHJpbms6IDA7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1z
OiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwogICAgICAgICAgICBib3JkZXI6IDEu
NXB4IHNvbGlkIHRyYW5zcGFyZW50OyBiYWNrZ3JvdW5kOiBub25lOyBjdXJzb3I6IHBvaW50ZXI7
CiAgICAgICAgICAgIGNvbG9yOiB2YXIoLS10eHQzKTsgYm9yZGVyLXJhZGl1czogdmFyKC0tcik7
CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8t
ZHJhZzsKICAgICAgICAgICAgdHJhbnNpdGlvbjogY29sb3IgdmFyKC0tdHIpLCBiYWNrZ3JvdW5k
IHZhcigtLXRyKSwgYm9yZGVyLWNvbG9yIHZhcigtLXRyKTsKICAgICAgICB9CiAgICAgICAgI2J0
bi1waW46aG92ZXIgeyBjb2xvcjogdmFyKC0tYWNjKTsgYmFja2dyb3VuZDogcmdiYSg5MSwxMTUs
MjMyLC4xKTsgfQogICAgICAgICNidG4tcGluLm9uICB7CiAgICAgICAgICAgIGNvbG9yOiB2YXIo
LS1hY2MpOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDkxLDExNSwyMzIsLjE4KTsKICAg
ICAgICAgICAgYm9yZGVyLWNvbG9yOiByZ2JhKDkxLDExNSwyMzIsLjU1KTsKICAgICAgICB9CiAg
ICAgICAgI2J0bi1waW4gc3ZnIHsgd2lkdGg6IDE0cHg7IGhlaWdodDogMTRweDsgZGlzcGxheTog
YmxvY2s7IH0KCiAgICAgICAgI2J0bi1sb2NhdGUgewogICAgICAgICAgICB3aWR0aDogMjhweDsg
aGVpZ2h0OiAyOHB4OyBmbGV4LXNocmluazogMDsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsg
YWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7CiAgICAgICAgICAg
IGJvcmRlcjogbm9uZTsgYmFja2dyb3VuZDogbm9uZTsgY3Vyc29yOiBwb2ludGVyOwogICAgICAg
ICAgICBjb2xvcjogdmFyKC0tdHh0Myk7IGJvcmRlci1yYWRpdXM6IHZhcigtLXIpOwogICAgICAg
ICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAg
ICAgICAgICAgIHRyYW5zaXRpb246IGNvbG9yIHZhcigtLXRyKSwgYmFja2dyb3VuZCB2YXIoLS10
ciksIG9wYWNpdHkgdmFyKC0tdHIpOwogICAgICAgIH0KICAgICAgICAjYnRuLWxvY2F0ZTpob3Zl
cjpub3QoOmRpc2FibGVkKSB7IGNvbG9yOiB2YXIoLS1hY2MpOyBiYWNrZ3JvdW5kOiByZ2JhKDkx
LDExNSwyMzIsLjEpOyB9CiAgICAgICAgI2J0bi1sb2NhdGU6ZGlzYWJsZWQgeyBvcGFjaXR5OiAu
MzU7IGN1cnNvcjogZGVmYXVsdDsgfQogICAgICAgICNidG4tbG9jYXRlLmhhcy10YXJnZXQgeyBj
b2xvcjogdmFyKC0tYWNjKTsgfQogICAgICAgICNidG4tbG9jYXRlLm9uIHsKICAgICAgICAgICAg
Y29sb3I6IHZhcigtLWFjYyk7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoOTEsMTE1LDIz
MiwuMTgpOwogICAgICAgIH0KICAgICAgICAjYnRuLWxvY2F0ZSBzdmcgeyB3aWR0aDogMTVweDsg
aGVpZ2h0OiAxNXB4OyBkaXNwbGF5OiBibG9jazsgfQogICAgICAgICNoZHI6aGFzKCNzZWFyY2gt
d3JhcC5vcGVuKSAjYnRuLWxvY2F0ZSB7CiAgICAgICAgICAgIGRpc3BsYXk6IG5vbmU7CiAgICAg
ICAgfQoKICAgICAgICAvKiDilIDilIAgUm93IDIg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSAICovCiAgICAgICAgI3RhYnMgewogICAg
ICAgICAgICBwb3NpdGlvbjogcmVsYXRpdmU7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFs
aWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogMnB4OyBmbGV4LXdyYXA6IG5vd3JhcDsKICAgICAgICAg
ICAgcGFkZGluZzogNXB4IDZweCA1cHggOHB4OyBmbGV4LXNocmluazogMDsKICAgICAgICAgICAg
YmFja2dyb3VuZDogI2YyZjRmOTsKICAgICAgICB9CiAgICAgICAgI3RhYi1pbmsgewogICAgICAg
ICAgICBwb3NpdGlvbjogYWJzb2x1dGU7CiAgICAgICAgICAgIGxlZnQ6IDA7IHRvcDogMDsKICAg
ICAgICAgICAgaGVpZ2h0OiAyMnB4OwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiA5OTlweDsK
ICAgICAgICAgICAgYmFja2dyb3VuZDogI2ZmZjsKICAgICAgICAgICAgYm94LXNoYWRvdzogMCAx
cHggM3B4IHJnYmEoMCwwLDAsLjA3KSwgMCAwIDAgMXB4IHJnYmEoOTEsMTE1LDIzMiwuMDYpOwog
ICAgICAgICAgICBwb2ludGVyLWV2ZW50czogbm9uZTsKICAgICAgICAgICAgei1pbmRleDogMDsK
ICAgICAgICAgICAgdHJhbnNmb3JtOiB0cmFuc2xhdGUzZCgwLDAsMCkgc2NhbGVYKDEpOwogICAg
ICAgICAgICB0cmFuc2Zvcm0tb3JpZ2luOiBjZW50ZXIgYm90dG9tOwogICAgICAgICAgICB0cmFu
c2l0aW9uOgogICAgICAgICAgICAgICAgdHJhbnNmb3JtIDAuMzRzIGN1YmljLWJlemllcigwLjIy
LCAxLjE4LCAwLjMyLCAxKSwKICAgICAgICAgICAgICAgIGhlaWdodCAwLjI0cyBlYXNlOwogICAg
ICAgICAgICB3aWxsLWNoYW5nZTogdHJhbnNmb3JtLCBoZWlnaHQ7CiAgICAgICAgfQogICAgICAg
ICN0YWItaW5rLnNxdWFzaCB7CiAgICAgICAgICAgIHRyYW5zaXRpb246CiAgICAgICAgICAgICAg
ICB0cmFuc2Zvcm0gMC4zMHMgY3ViaWMtYmV6aWVyKDAuMzQsIDEuMjgsIDAuNDQsIDEpLAogICAg
ICAgICAgICAgICAgaGVpZ2h0IDAuMjBzIGVhc2U7CiAgICAgICAgfQogICAgICAgIC50YWIgewog
ICAgICAgICAgICBwb3NpdGlvbjogcmVsYXRpdmU7CiAgICAgICAgICAgIHotaW5kZXg6IDE7CiAg
ICAgICAgICAgIHBhZGRpbmc6IDNweCAxMHB4OyBmb250LXNpemU6IDExcHg7IGNvbG9yOiB2YXIo
LS10eHQyKTsgY3Vyc29yOiBwb2ludGVyOwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiA5OTlw
eDsgd2hpdGUtc3BhY2U6IG5vd3JhcDsKICAgICAgICAgICAgYmFja2dyb3VuZDogdHJhbnNwYXJl
bnQ7CiAgICAgICAgICAgIHRyYW5zaXRpb246IGNvbG9yIDAuMjhzIGN1YmljLWJlemllcigwLjIy
LCAxLCAwLjM2LCAxKSwKICAgICAgICAgICAgICAgICAgICAgICAgdHJhbnNmb3JtIDAuMjhzIGN1
YmljLWJlemllcigwLjIyLCAxLCAwLjM2LCAxKTsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVn
aW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgIH0KICAgICAgICAudGFi
OmhvdmVyIHsgY29sb3I6IHZhcigtLXR4dCk7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OyB9CiAg
ICAgICAgLnRhYjphY3RpdmUgeyB0cmFuc2Zvcm06IHNjYWxlKDAuOTYpOyB9CiAgICAgICAgLnRh
Yi5vbiB7IGNvbG9yOiB2YXIoLS1hY2MpOyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsgYm94LXNo
YWRvdzogbm9uZTsgZm9udC13ZWlnaHQ6IDYwMDsgfQogICAgICAgIC5iYWRnZSB7CiAgICAgICAg
ICAgIGRpc3BsYXk6IGlubGluZS1mbGV4OyBtaW4td2lkdGg6IDE0cHg7IGhlaWdodDogMTRweDsg
cGFkZGluZzogMCAzcHg7CiAgICAgICAgICAgIGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnkt
Y29udGVudDogY2VudGVyOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiB2YXIoLS1hY2MpOyBjb2xv
cjogI2ZmZjsgZm9udC1zaXplOiA5cHg7IGJvcmRlci1yYWRpdXM6IDdweDsgZm9udC13ZWlnaHQ6
IDcwMDsKICAgICAgICB9CiAgICAgICAgI3RhYi1hY3Rpb25zIHsKICAgICAgICAgICAgbWFyZ2lu
LWxlZnQ6IGF1dG87IGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogNHB4
OwogICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0Myk7IGZvbnQtc2l6ZTogMTBweDsKICAgICAg
ICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwog
ICAgICAgIH0KICAgICAgICAjYmFyLXR4dCB7IHdoaXRlLXNwYWNlOiBub3dyYXA7IH0KICAgICAg
ICAjYnRuLWNsciB7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50
ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwogICAgICAgICAgICB3aWR0aDogMjZweDsgaGVp
Z2h0OiAyNnB4OyBib3JkZXI6IG5vbmU7IGJhY2tncm91bmQ6IG5vbmU7IGNvbG9yOiB2YXIoLS10
eHQzKTsKICAgICAgICAgICAgY3Vyc29yOiBwb2ludGVyOyBib3JkZXItcmFkaXVzOiB2YXIoLS1y
KTsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBu
by1kcmFnOwogICAgICAgICAgICB0cmFuc2l0aW9uOiBjb2xvciB2YXIoLS10ciksIGJhY2tncm91
bmQgdmFyKC0tdHIpOwogICAgICAgIH0KICAgICAgICAjYnRuLWNscjpob3ZlciB7IGNvbG9yOiAj
ZmY3YjljOyBiYWNrZ3JvdW5kOiByZ2JhKDI1NSwxMjMsMTU2LC4wOCk7IH0KICAgICAgICAjYnRu
LWNsciBzdmcgeyB3aWR0aDogMTRweDsgaGVpZ2h0OiAxNHB4OyBkaXNwbGF5OiBibG9jazsgfQoK
ICAgICAgICAvKiDilIDilIAgTGlzdCDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIAgKi8KICAgICAgICAjbGlzdCB7CiAgICAgICAg
ICAgIGZsZXg6IDE7IG92ZXJmbG93LXk6IGF1dG87IG92ZXJmbG93LXg6IGhpZGRlbjsgcGFkZGlu
ZzogNnB4IDhweCA2cHggMTBweDsgY3Vyc29yOiBkZWZhdWx0OwogICAgICAgICAgICAtd2Via2l0
LWFwcC1yZWdpb246IGRyYWc7IGFwcC1yZWdpb246IGRyYWc7CiAgICAgICAgICAgIG1pbi1oZWln
aHQ6IDA7CiAgICAgICAgfQogICAgICAgIEBrZXlmcmFtZXMgdGFiUGFuZUluTHIgewogICAgICAg
ICAgICBmcm9tIHsgb3BhY2l0eTogMDsgdHJhbnNmb3JtOiB0cmFuc2xhdGVYKC0yMnB4KTsgfQog
ICAgICAgICAgICB0byB7IG9wYWNpdHk6IDE7IHRyYW5zZm9ybTogdHJhbnNsYXRlWCgwKTsgfQog
ICAgICAgIH0KICAgICAgICBAa2V5ZnJhbWVzIHRhYlBhbmVJblJsIHsKICAgICAgICAgICAgZnJv
bSB7IG9wYWNpdHk6IDA7IHRyYW5zZm9ybTogdHJhbnNsYXRlWCgyMnB4KTsgfQogICAgICAgICAg
ICB0byB7IG9wYWNpdHk6IDE7IHRyYW5zZm9ybTogdHJhbnNsYXRlWCgwKTsgfQogICAgICAgIH0K
ICAgICAgICAjYnRuLXRvcCB7CiAgICAgICAgICAgIHBvc2l0aW9uOiBhYnNvbHV0ZTsgcmlnaHQ6
IDEwcHg7IGJvdHRvbTogMTBweDsgei1pbmRleDogMjA7CiAgICAgICAgICAgIHdpZHRoOiAyOHB4
OyBoZWlnaHQ6IDI4cHg7IGJvcmRlcjogbm9uZTsgYm9yZGVyLXJhZGl1czogNTAlOwogICAgICAg
ICAgICBkaXNwbGF5OiBub25lOyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6
IGNlbnRlcjsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2ZmZjsgY29sb3I6IHZhcigtLXR4dDIp
OwogICAgICAgICAgICBib3gtc2hhZG93OiAwIDJweCA4cHggcmdiYSgyNCwzMiw1NiwuMTYpOwog
ICAgICAgICAgICBjdXJzb3I6IHBvaW50ZXI7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lv
bjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICAgICAgdHJhbnNpdGlvbjog
YmFja2dyb3VuZCB2YXIoLS10ciksIGNvbG9yIHZhcigtLXRyKSwgYm94LXNoYWRvdyB2YXIoLS10
cik7CiAgICAgICAgfQogICAgICAgICNidG4tdG9wLm9uIHsgZGlzcGxheTogZmxleDsgfQogICAg
ICAgICNidG4tdG9wOmhvdmVyIHsgY29sb3I6IHZhcigtLWFjYyk7IGJhY2tncm91bmQ6ICNlZGYx
ZmY7IGJveC1zaGFkb3c6IDAgM3B4IDEwcHggcmdiYSg5MSwxMTUsMjMyLC4yNSk7IH0KICAgICAg
ICAjYnRuLXRvcCBzdmcgeyB3aWR0aDogMTRweDsgaGVpZ2h0OiAxNHB4OyBkaXNwbGF5OiBibG9j
azsgfQogICAgICAgICNlbXB0eSB7CiAgICAgICAgICAgIGRpc3BsYXk6IG5vbmU7IGZsZXgtZGly
ZWN0aW9uOiBjb2x1bW47IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2Vu
dGVyOwogICAgICAgICAgICBwYWRkaW5nOiA0OHB4IDE2cHg7IGNvbG9yOiB2YXIoLS10eHQzKTsg
Z2FwOiA4cHg7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogZHJhZzsgYXBwLXJlZ2lv
bjogZHJhZzsKICAgICAgICB9CiAgICAgICAgI2VtcHR5Lm9uIHsgZGlzcGxheTogZmxleDsgfQog
ICAgICAgIC5lLXR4dCB7IGZvbnQtc2l6ZTogMTJweDsgdGV4dC1hbGlnbjogY2VudGVyOyBsZXR0
ZXItc3BhY2luZzogLjAyZW07IH0KICAgICAgICAjc2tlbCB7CiAgICAgICAgICAgIGRpc3BsYXk6
IG5vbmU7IGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47IGdhcDogOHB4OwogICAgICAgICAgICBwYWRk
aW5nOiA0cHggMnB4IDEwcHg7IC13ZWJraXQtYXBwLXJlZ2lvbjogZHJhZzsgYXBwLXJlZ2lvbjog
ZHJhZzsKICAgICAgICB9CiAgICAgICAgI3NrZWwub24geyBkaXNwbGF5OiBmbGV4OyB9CiAgICAg
ICAgI2FwcC5ib290LWxvYWRpbmcgI3NrZWwgewogICAgICAgICAgICBkaXNwbGF5OiBmbGV4ICFp
bXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgICNhcHAuYm9vdC1sb2FkaW5nICNlbXB0eSB7CiAg
ICAgICAgICAgIGRpc3BsYXk6IG5vbmUgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgLnNr
LXJvdyB7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBmbGV4LXN0YXJ0
OyBnYXA6IDEwcHg7CiAgICAgICAgICAgIHBhZGRpbmc6IDEwcHggOHB4OyBib3JkZXItcmFkaXVz
OiA4cHg7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoMjU1LDI1NSwyNTUsLjcyKTsKICAg
ICAgICAgICAgYm9yZGVyOiAxcHggc29saWQgcmdiYSgxNzAsMTgwLDIwMCwuNDUpOwogICAgICAg
ICAgICBwb3NpdGlvbjogcmVsYXRpdmU7CiAgICAgICAgICAgIG92ZXJmbG93OiBoaWRkZW47CiAg
ICAgICAgfQogICAgICAgIC5zay1yb3c6OmFmdGVyIHsKICAgICAgICAgICAgY29udGVudDogJyc7
CiAgICAgICAgICAgIHBvc2l0aW9uOiBhYnNvbHV0ZTsKICAgICAgICAgICAgaW5zZXQ6IDA7CiAg
ICAgICAgICAgIGJhY2tncm91bmQ6IGxpbmVhci1ncmFkaWVudCg5MGRlZywgdHJhbnNwYXJlbnQg
MCUsIHJnYmEoMjU1LDI1NSwyNTUsLjcyKSA0OCUsIHRyYW5zcGFyZW50IDEwMCUpOwogICAgICAg
ICAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVgoLTEyMCUpOwogICAgICAgICAgICBhbmltYXRpb246
IHNrLXN3ZWVwIDAuOTVzIGVhc2UtaW4tb3V0IGluZmluaXRlOwogICAgICAgICAgICBwb2ludGVy
LWV2ZW50czogbm9uZTsKICAgICAgICB9CiAgICAgICAgQGtleWZyYW1lcyBzay1zd2VlcCB7CiAg
ICAgICAgICAgIDEwMCUgeyB0cmFuc2Zvcm06IHRyYW5zbGF0ZVgoMTIwJSk7IH0KICAgICAgICB9
CiAgICAgICAgLnNrLWljbywgLnNrLWxpbmUgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiBsaW5l
YXItZ3JhZGllbnQoOTBkZWcsICNiOGMyZDggMCUsICNmMGY0ZmEgMzglLCAjZGNlM2YwIDUyJSwg
I2I4YzJkOCAxMDAlKTsKICAgICAgICAgICAgYmFja2dyb3VuZC1zaXplOiAyNDAlIDEwMCU7CiAg
ICAgICAgICAgIGFuaW1hdGlvbjogc2stc2hpbW1lciAwLjcycyBlYXNlLWluLW91dCBpbmZpbml0
ZTsKICAgICAgICAgICAgd2lsbC1jaGFuZ2U6IGJhY2tncm91bmQtcG9zaXRpb247CiAgICAgICAg
ICAgIGJvcmRlci1yYWRpdXM6IDZweDsKICAgICAgICB9CiAgICAgICAgLnNrLWljbyB7IHdpZHRo
OiAzNHB4OyBoZWlnaHQ6IDM0cHg7IGZsZXgtc2hyaW5rOiAwOyBib3JkZXItcmFkaXVzOiA4cHg7
IH0KICAgICAgICAuc2stYm9keSB7IGZsZXg6IDE7IG1pbi13aWR0aDogMDsgZGlzcGxheTogZmxl
eDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgZ2FwOiA4cHg7IHBhZGRpbmctdG9wOiAycHg7IH0K
ICAgICAgICAuc2stbGluZSB7IGhlaWdodDogMTBweDsgd2lkdGg6IDEwMCU7IH0KICAgICAgICAu
c2stbGluZS5zaG9ydCB7IHdpZHRoOiA0MiU7IH0KICAgICAgICAuc2stbGluZS5taWQgeyB3aWR0
aDogNjglOyB9CiAgICAgICAgLnNrLXJvdzpudGgtY2hpbGQoMik6OmFmdGVyIHsgYW5pbWF0aW9u
LWRlbGF5OiAuMTJzOyB9CiAgICAgICAgLnNrLXJvdzpudGgtY2hpbGQoMyk6OmFmdGVyIHsgYW5p
bWF0aW9uLWRlbGF5OiAuMjRzOyB9CiAgICAgICAgLnNrLXJvdzpudGgtY2hpbGQoNCk6OmFmdGVy
IHsgYW5pbWF0aW9uLWRlbGF5OiAuMzZzOyB9CiAgICAgICAgLnNrLXJvdzpudGgtY2hpbGQoNSk6
OmFmdGVyIHsgYW5pbWF0aW9uLWRlbGF5OiAuNDhzOyB9CiAgICAgICAgLnNrLXJvdzpudGgtY2hp
bGQoNik6OmFmdGVyIHsgYW5pbWF0aW9uLWRlbGF5OiAuNnM7IH0KICAgICAgICBAa2V5ZnJhbWVz
IHNrLXNoaW1tZXIgewogICAgICAgICAgICAwJSB7IGJhY2tncm91bmQtcG9zaXRpb246IDEwMCUg
MDsgfQogICAgICAgICAgICAxMDAlIHsgYmFja2dyb3VuZC1wb3NpdGlvbjogLTEwMCUgMDsgfQog
ICAgICAgIH0KICAgICAgICAubGlzdC1tb3JlIHsKICAgICAgICAgICAgdGV4dC1hbGlnbjogY2Vu
dGVyOyBwYWRkaW5nOiAxMHB4IDhweCAxNHB4OyBmb250LXNpemU6IDExcHg7CiAgICAgICAgICAg
IGNvbG9yOiB2YXIoLS10eHQzKTsgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVn
aW9uOiBuby1kcmFnOwogICAgICAgIH0KICAgICAgICAubGlzdC1tb3JlLmRvbmUgeyBkaXNwbGF5
OiBub25lOyB9CgogICAgICAgIC5pdG0gewogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBhbGln
bi1pdGVtczogZmxleC1zdGFydDsgZ2FwOiA4cHg7CiAgICAgICAgICAgIHBhZGRpbmc6IDhweDsg
bWFyZ2luLWJvdHRvbTogNXB4OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiB2YXIoLS1jYXJkKTsg
Ym9yZGVyLXJhZGl1czogdmFyKC0tcik7IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICAgICAgYm94
LXNoYWRvdzogMCAxcHggM3B4IHJnYmEoMjQsMzIsNTYsLjA2KTsKICAgICAgICAgICAgLyogaG92
ZXItbGluZSAqLwogICAgICAgICAgICBwb3NpdGlvbjogcmVsYXRpdmU7CiAgICAgICAgICAgIHRy
YW5zaXRpb246IGJhY2tncm91bmQgLjJzIGVhc2UsIGJveC1zaGFkb3cgLjJzIGVhc2U7CiAgICAg
ICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsK
ICAgICAgICAgICAgb3ZlcmZsb3c6IHZpc2libGU7CiAgICAgICAgfQogICAgICAgIC5pdG06OmJl
Zm9yZSB7CiAgICAgICAgICAgIGNvbnRlbnQ6ICIiOwogICAgICAgICAgICBwb3NpdGlvbjogYWJz
b2x1dGU7CiAgICAgICAgICAgIGxlZnQ6IDA7IHJpZ2h0OiAwOyBib3R0b206IDA7CiAgICAgICAg
ICAgIGhlaWdodDogMDsKICAgICAgICAgICAgcG9pbnRlci1ldmVudHM6IG5vbmU7CiAgICAgICAg
ICAgIHotaW5kZXg6IDA7CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6IDAgMCB2YXIoLS1yKSB2
YXIoLS1yKTsKICAgICAgICAgICAgYmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50KHRvIHRvcCwg
cmdiYSg5MSwxMTUsMjMyLC4zMiksIHJnYmEoOTEsMTE1LDIzMiwuMTIpIDU1JSwgdHJhbnNwYXJl
bnQpOwogICAgICAgICAgICB0cmFuc2l0aW9uOiBoZWlnaHQgLjM0cyBjdWJpYy1iZXppZXIoLjIy
LDEsLjM2LDEpOwogICAgICAgIH0KICAgICAgICAuaXRtOmhvdmVyOjpiZWZvcmUgeyBoZWlnaHQ6
IDMzLjMzMyU7IH0KICAgICAgICAuaXRtOjphZnRlciB7CiAgICAgICAgICAgIGNvbnRlbnQ6ICIi
OwogICAgICAgICAgICBwb3NpdGlvbjogYWJzb2x1dGU7CiAgICAgICAgICAgIGxlZnQ6IDA7IHJp
Z2h0OiAwOyBib3R0b206IDA7CiAgICAgICAgICAgIGhlaWdodDogMnB4OwogICAgICAgICAgICBw
b2ludGVyLWV2ZW50czogbm9uZTsKICAgICAgICAgICAgei1pbmRleDogMTsKICAgICAgICAgICAg
YmFja2dyb3VuZDogcmdiYSg5MSwxMTUsMjMyLC45NSk7CiAgICAgICAgICAgIGJvcmRlci1yYWRp
dXM6IDFweDsKICAgICAgICAgICAgdHJhbnNmb3JtOiBzY2FsZVgoMCk7CiAgICAgICAgICAgIHRy
YW5zZm9ybS1vcmlnaW46IGNlbnRlcjsKICAgICAgICAgICAgdHJhbnNpdGlvbjogdHJhbnNmb3Jt
IC4zcyBjdWJpYy1iZXppZXIoLjIyLDEsLjM2LDEpOwogICAgICAgIH0KICAgICAgICAuaXRtOmhv
dmVyIHsKICAgICAgICAgICAgYmFja2dyb3VuZDogdmFyKC0tY2FyZC1oKTsKICAgICAgICAgICAg
Ym94LXNoYWRvdzogMCAycHggOHB4IHJnYmEoMjQsMzIsNTYsLjEpOwogICAgICAgIH0KICAgICAg
ICAuaXRtOmhvdmVyOjphZnRlciB7CiAgICAgICAgICAgIHRyYW5zZm9ybTogc2NhbGVYKDEpOwog
ICAgICAgIH0KICAgICAgICAuaXRtLnNlbCB7CiAgICAgICAgICAgIGJveC1zaGFkb3c6IDAgMCAw
IDJweCByZ2JhKDkxLDExNSwyMzIsLjQ1KSwgMCAycHggOHB4IHJnYmEoOTEsMTE1LDIzMiwuMTgp
OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZWRmMWZmOwogICAgICAgIH0KICAgICAgICAuaXRt
Lm11bHRpIHsKICAgICAgICAgICAgYm94LXNoYWRvdzogMCAwIDAgMS41cHggcmdiYSg5MSwxMTUs
MjMyLC41NSksIDAgMnB4IDZweCByZ2JhKDkxLDExNSwyMzIsLjE4KTsKICAgICAgICAgICAgYmFj
a2dyb3VuZDogI2VlZjJmZjsKICAgICAgICB9CiAgICAgICAgLml0bS5tdWx0aS5zZWwgewogICAg
ICAgICAgICBib3gtc2hhZG93OiAwIDAgMCAycHggcmdiYSg5MSwxMTUsMjMyLC43KSwgMCAycHgg
OHB4IHJnYmEoOTEsMTE1LDIzMiwuMjIpOwogICAgICAgIH0KCiAgICAgICAgI211bHRpLWNudCB7
CiAgICAgICAgICAgIGRpc3BsYXk6IG5vbmU7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnkt
Y29udGVudDogY2VudGVyOwogICAgICAgICAgICBoZWlnaHQ6IDIycHg7IHBhZGRpbmc6IDAgOHB4
OyBtYXJnaW4tcmlnaHQ6IDRweDsKICAgICAgICAgICAgYm9yZGVyOiBub25lOyBib3JkZXItcmFk
aXVzOiAxMXB4OyBjdXJzb3I6IHBvaW50ZXI7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHZhcigt
LWFjYyk7IGNvbG9yOiAjZmZmOyBmb250LXNpemU6IDExcHg7IGZvbnQtd2VpZ2h0OiA3MDA7CiAg
ICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJh
ZzsKICAgICAgICAgICAgdHJhbnNpdGlvbjogb3BhY2l0eSB2YXIoLS10ciksIGJhY2tncm91bmQg
dmFyKC0tdHIpOwogICAgICAgIH0KICAgICAgICAjbXVsdGktY250OmhvdmVyIHsgYmFja2dyb3Vu
ZDogIzRhNjJkNDsgfQogICAgICAgICNtdWx0aS1jbnQub24geyBkaXNwbGF5OiBpbmxpbmUtZmxl
eDsgfQoKICAgICAgICAuaS1pY28gewogICAgICAgICAgICB3aWR0aDogMjhweDsgaGVpZ2h0OiAy
OHB4OyBib3JkZXItcmFkaXVzOiB2YXIoLS1yKTsgZGlzcGxheTogZmxleDsKICAgICAgICAgICAg
YWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7IGZsZXgtc2hyaW5r
OiAwOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZWRmMmZmOyBjb2xvcjogdmFyKC0tYWNjKTsK
ICAgICAgICAgICAgcG9zaXRpb246IHJlbGF0aXZlOyBvdmVyZmxvdzogdmlzaWJsZTsKICAgICAg
ICB9CiAgICAgICAgLmktaWNvIHN2ZyB7IHdpZHRoOiAxNnB4OyBoZWlnaHQ6IDE2cHg7IGRpc3Bs
YXk6IGJsb2NrOyB9CiAgICAgICAgLmktaWNvLmZ0LWltZyB7IGNvbG9yOiAjN2FkN2ZmOyB9CiAg
ICAgICAgLmktaWNvLmZ0LXZpZCB7IGNvbG9yOiAjYzA4NGZjOyB9CiAgICAgICAgLmktaWNvLmZ0
LXppcCB7IGNvbG9yOiAjOGFiNGZmOyB9CiAgICAgICAgLmktaWNvLmZ0LWRpciB7IGNvbG9yOiAj
ZmZkNTZhOyB9CiAgICAgICAgLmktaWNvLmZ0LWFoayB7IGNvbG9yOiAjNmRmZjlhOyB9CiAgICAg
ICAgLmktaWNvLm1kIHsgY29sb3I6ICM2YjhjZmY7IH0KICAgICAgICAuaS1pY28ubWQgc3ZnIHsg
d2lkdGg6IDIwcHg7IGhlaWdodDogMjBweDsgfQogICAgICAgIC5pLWljby5mdC1sbmssIC5pLWlj
by5mdC1kb2MgeyBjb2xvcjogI2E5YmRkMDsgfQogICAgICAgIC5pLXVzZWQgewogICAgICAgICAg
ICBwb3NpdGlvbjogYWJzb2x1dGU7IHJpZ2h0OiAwOyBib3R0b206IDA7CiAgICAgICAgICAgIHdp
ZHRoOiAxM3B4OyBoZWlnaHQ6IDEzcHg7IGJvcmRlci1yYWRpdXM6IDUwJTsKICAgICAgICAgICAg
YmFja2dyb3VuZDogIzIyYzU1ZTsgYm9yZGVyOiAxLjVweCBzb2xpZCAjZmZmOwogICAgICAgICAg
ICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNl
bnRlcjsKICAgICAgICAgICAgcG9pbnRlci1ldmVudHM6IG5vbmU7IHotaW5kZXg6IDM7CiAgICAg
ICAgICAgIGJveC1zaGFkb3c6IDAgMXB4IDJweCByZ2JhKDAsMCwwLC4xNik7CiAgICAgICAgICAg
IHRyYW5zZm9ybTogdHJhbnNsYXRlKDMwJSwgMzAlKTsKICAgICAgICB9CiAgICAgICAgLmktdXNl
ZCBzdmcgeyB3aWR0aDogOXB4OyBoZWlnaHQ6IDlweDsgY29sb3I6ICNmZmY7IGRpc3BsYXk6IGJs
b2NrOyB9CgogICAgICAgIC5pdG0uanVtcC1mbGFzaCB7CiAgICAgICAgICAgIGJveC1zaGFkb3c6
IDAgMCAwIDJweCByZ2JhKDkxLDExNSwyMzIsLjU1KSwgMCAycHggMTBweCByZ2JhKDkxLDExNSwy
MzIsLjIyKTsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2U4ZWRmZjsKICAgICAgICAgICAgdHJh
bnNpdGlvbjogYmFja2dyb3VuZCAuMzVzIGVhc2UsIGJveC1zaGFkb3cgLjM1cyBlYXNlOwogICAg
ICAgIH0KCiAgICAgICAgLmktYm9keSB7IGZsZXg6IDE7IG1pbi13aWR0aDogMDsgZGlzcGxheTog
ZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgfQogICAgICAgIC5pLXByZXYsIC5pLW5hbWUg
ewogICAgICAgICAgICBmb250LXNpemU6IDEzcHg7IGZvbnQtd2VpZ2h0OiA1MDA7IGNvbG9yOiB2
YXIoLS10eHQpOyB3b3JkLWJyZWFrOiBicmVhay1hbGw7CiAgICAgICAgICAgIHdoaXRlLXNwYWNl
OiBwcmUtd3JhcDsgLyog5pSv5oyB5aSa5paH5Lu2L+WkmuihjOaWh+acrOaNouihjOaYvuekuiAq
LwogICAgICAgIH0KICAgICAgICAuaS1wcmV2IHsKICAgICAgICAgICAgZGlzcGxheTogLXdlYmtp
dC1ib3g7IC13ZWJraXQtYm94LW9yaWVudDogdmVydGljYWw7IC13ZWJraXQtbGluZS1jbGFtcDog
NTsgb3ZlcmZsb3c6IGhpZGRlbjsKICAgICAgICAgICAgdGV4dC1vdmVyZmxvdzogZWxsaXBzaXM7
CiAgICAgICAgfQogICAgICAgIC5pLW5hbWUgewogICAgICAgICAgICBkaXNwbGF5OiAtd2Via2l0
LWJveDsgLXdlYmtpdC1ib3gtb3JpZW50OiB2ZXJ0aWNhbDsgLXdlYmtpdC1saW5lLWNsYW1wOiAy
OyBvdmVyZmxvdzogaGlkZGVuOwogICAgICAgIH0KICAgICAgICAvKiBGaWxlIGNsaXAgd2hvc2Ug
cGF0aChzKSBubyBsb25nZXIgZXhpc3Qg4oCUIGxpZ2h0IGJvbGQgZ3JheSBzdHJpa2UgKi8KICAg
ICAgICAuaXRtLmdvbmUgLmktbmFtZSB7CiAgICAgICAgICAgIGNvbG9yOiAjOWFhMGIwOwogICAg
ICAgICAgICB0ZXh0LWRlY29yYXRpb246IGxpbmUtdGhyb3VnaDsKICAgICAgICAgICAgdGV4dC1k
ZWNvcmF0aW9uLXRoaWNrbmVzczogMnB4OwogICAgICAgICAgICB0ZXh0LWRlY29yYXRpb24tY29s
b3I6IHJnYmEoMTU0LCAxNjAsIDE3NiwgLjU1KTsKICAgICAgICAgICAgdGV4dC1kZWNvcmF0aW9u
LXNraXAtaW5rOiBub25lOwogICAgICAgIH0KICAgICAgICAuaXRtLmdvbmUgLmktaWNvIHsgb3Bh
Y2l0eTogLjU1OyB9CiAgICAgICAgLml0bS5nb25lIC5pLXRodW1iLXdyYXAgeyBvcGFjaXR5OiAu
NTU7IH0KICAgICAgICAuaS1wcmV2LnVybCB7IGNvbG9yOiB2YXIoLS1hY2MpOyB9CiAgICAgICAg
LmktdGh1bWItd3JhcCB7CiAgICAgICAgICAgIHdpZHRoOiAxMDAlOyBtaW4taGVpZ2h0OiA0OHB4
OyBtYXgtaGVpZ2h0OiAxODBweDsgbWFyZ2luLWJvdHRvbTogNHB4OwogICAgICAgICAgICBkaXNw
bGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsK
ICAgICAgICAgICAgYmFja2dyb3VuZDogI2YzZjVmOTsgYm9yZGVyLXJhZGl1czogdmFyKC0tcik7
IG92ZXJmbG93OiBoaWRkZW47CiAgICAgICAgfQogICAgICAgIC5pLXRodW1iIHsgbWF4LXdpZHRo
OiAxMDAlOyBtYXgtaGVpZ2h0OiAxODBweDsgd2lkdGg6IGF1dG87IGhlaWdodDogYXV0bzsgb2Jq
ZWN0LWZpdDogY29udGFpbjsgZGlzcGxheTogYmxvY2s7IH0KCiAgICAgICAgLyogTWV0YSBiYXI6
IHRpbWUgbGVmdCB8IGV4cGFuZCBjZW50ZXIgfCB0YWdzIHJpZ2h0ICovCiAgICAgICAgLmktbWV0
YSB7CiAgICAgICAgICAgIGRpc3BsYXk6IGdyaWQ7CiAgICAgICAgICAgIGdyaWQtdGVtcGxhdGUt
Y29sdW1uczogMWZyIGF1dG8gMWZyOwogICAgICAgICAgICBhbGlnbi1pdGVtczogY2VudGVyOwog
ICAgICAgICAgICBnYXA6IDRweDsKICAgICAgICAgICAgbWFyZ2luLXRvcDogNHB4OwogICAgICAg
ICAgICB3aWR0aDogMTAwJTsKICAgICAgICB9CiAgICAgICAgLmktbWV0YSAuaS10aW1lIHsganVz
dGlmeS1zZWxmOiBzdGFydDsgfQogICAgICAgIC5pLW1ldGEtY2VudGVyIHsKICAgICAgICAgICAg
anVzdGlmeS1zZWxmOiBjZW50ZXI7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0
ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwogICAgICAgICAgICBnYXA6IDRw
eDsKICAgICAgICAgICAgbWluLXdpZHRoOiAxcHg7IC8qIGtlZXAgY2VudGVyIGNvbHVtbiBldmVu
IHdoZW4gZXhwYW5kIGlzIGhpZGRlbiAqLwogICAgICAgIH0KICAgICAgICAuaS1tZXRhLXJpZ2h0
IHsKICAgICAgICAgICAganVzdGlmeS1zZWxmOiBlbmQ7CiAgICAgICAgICAgIGRpc3BsYXk6IGZs
ZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogNXB4OyBmbGV4LXdyYXA6IHdyYXA7CiAgICAg
ICAgICAgIGp1c3RpZnktY29udGVudDogZmxleC1lbmQ7CiAgICAgICAgfQogICAgICAgIC5pLW1l
dGEtcmlnaHQudGV4dC1tZXRhIHsKICAgICAgICAgICAgZmxleC13cmFwOiBub3dyYXA7CiAgICAg
ICAgICAgIGdhcDogNHB4OwogICAgICAgIH0KICAgICAgICAuaS10aW1lLCAuaS10YWcgeyBmb250
LXNpemU6IDEwcHg7IGNvbG9yOiB2YXIoLS10eHQzKTsgfQogICAgICAgIC5pLXRhZyB7CiAgICAg
ICAgICAgIGJhY2tncm91bmQ6ICNmMWYzZjg7IHBhZGRpbmc6IDAgNXB4OyBib3JkZXItcmFkaXVz
OiAzcHg7CiAgICAgICAgICAgIHdoaXRlLXNwYWNlOiBub3dyYXA7IGZsZXgtc2hyaW5rOiAwOyBs
aW5lLWhlaWdodDogMS40OwogICAgICAgIH0KICAgICAgICAuaS1jaGFycyB7CiAgICAgICAgICAg
IGZvbnQtc2l6ZTogMTBweDsgY29sb3I6IHZhcigtLXR4dDMpOwogICAgICAgICAgICBiYWNrZ3Jv
dW5kOiAjZjFmM2Y4OyBwYWRkaW5nOiAwIDVweDsgYm9yZGVyLXJhZGl1czogM3B4OwogICAgICAg
ICAgICBmb250LXZhcmlhbnQtbnVtZXJpYzogdGFidWxhci1udW1zOwogICAgICAgICAgICB3aGl0
ZS1zcGFjZTogbm93cmFwOwogICAgICAgICAgICBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24t
aXRlbXM6IGJhc2VsaW5lOyBnYXA6IDJweDsKICAgICAgICB9CiAgICAgICAgLmktY2hhcnMgLm4g
ewogICAgICAgICAgICBkaXNwbGF5OiBpbmxpbmUtYmxvY2s7CiAgICAgICAgICAgIG1pbi13aWR0
aDogNGNoOwogICAgICAgICAgICB0ZXh0LWFsaWduOiByaWdodDsKICAgICAgICAgICAgZm9udC1m
YW1pbHk6ICdDYXNjYWRpYSBNb25vJywgJ0NvbnNvbGFzJywgJ1NhcmFzYSBNb25vIFNDJywgdWkt
bW9ub3NwYWNlLCBtb25vc3BhY2U7CiAgICAgICAgICAgIGZvbnQtd2VpZ2h0OiA2MDA7CiAgICAg
ICAgICAgIGNvbG9yOiB2YXIoLS10eHQyKTsKICAgICAgICB9CiAgICAgICAgLyogc3JjLXRpdGxl
LXRpcCAqLwogICAgICAgIC5pLXNyYy1pY28sIC5tZy1zcmMgeyBjdXJzb3I6IHBvaW50ZXI7IH0K
ICAgICAgICAjc3JjLXRpcCB7CiAgICAgICAgICAgIHBvc2l0aW9uOiBmaXhlZDsgei1pbmRleDog
OTk5OTk7CiAgICAgICAgICAgIG1heC13aWR0aDogbWluKDI4MHB4LCBjYWxjKDEwMHZ3IC0gMTZw
eCkpOwogICAgICAgICAgICBwYWRkaW5nOiA2cHggMTBweDsKICAgICAgICAgICAgYm9yZGVyLXJh
ZGl1czogOHB4OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDMyLDM2LDQ4LC45Mik7IGNv
bG9yOiAjZmZmOwogICAgICAgICAgICBmb250LXNpemU6IDEycHg7IGxpbmUtaGVpZ2h0OiAxLjM1
OwogICAgICAgICAgICBib3gtc2hhZG93OiAwIDZweCAxOHB4IHJnYmEoMCwwLDAsLjIyKTsKICAg
ICAgICAgICAgcG9pbnRlci1ldmVudHM6IG5vbmU7CiAgICAgICAgICAgIG9wYWNpdHk6IDA7IHRy
YW5zZm9ybTogdHJhbnNsYXRlWSg0cHgpOwogICAgICAgICAgICB0cmFuc2l0aW9uOiBvcGFjaXR5
IC4ycyBlYXNlLCB0cmFuc2Zvcm0gLjIycyBjdWJpYy1iZXppZXIoLjIyLDEsLjM2LDEpOwogICAg
ICAgICAgICB3b3JkLWJyZWFrOiBicmVhay13b3JkOwogICAgICAgIH0KICAgICAgICAjc3JjLXRp
cC5zaG93IHsgb3BhY2l0eTogMTsgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKDApOyB9CiAgICAgICAg
Lmktc3JjLWljbyB7CiAgICAgICAgICAgIHdpZHRoOiAxNHB4OyBoZWlnaHQ6IDE0cHg7IGZsZXgt
c2hyaW5rOiAwOwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiAycHg7IG9iamVjdC1maXQ6IGNv
bnRhaW47CiAgICAgICAgICAgIGRpc3BsYXk6IGJsb2NrOwogICAgICAgIH0KICAgICAgICAuaS1u
dW0gewogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBh
bGlnbi1pdGVtczogZmxleC1lbmQ7CiAgICAgICAgICAgIGp1c3RpZnktY29udGVudDogc3BhY2Ut
YmV0d2VlbjsKICAgICAgICAgICAgYWxpZ24tc2VsZjogc3RyZXRjaDsKICAgICAgICAgICAgZm9u
dC1zaXplOiAxMHB4OyBjb2xvcjogdmFyKC0tdHh0Myk7IG1pbi13aWR0aDogMTZweDsKICAgICAg
ICAgICAgdGV4dC1hbGlnbjogcmlnaHQ7IGZsZXgtc2hyaW5rOiAwOwogICAgICAgICAgICBwYWRk
aW5nLXRvcDogMnB4OwogICAgICAgIH0KICAgICAgICAuaS1udW0gLmktc3JjLWljbyB7IHdpZHRo
OiAxNnB4OyBoZWlnaHQ6IDE2cHg7IG1hcmdpbi10b3A6IGF1dG87IH0KCiAgICAgICAgLmktZXhw
YW5kLWJ0biB7CiAgICAgICAgICAgIGJvcmRlcjogbm9uZTsgYmFja2dyb3VuZDogbm9uZTsgY3Vy
c29yOiBwb2ludGVyOwogICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0Myk7IGZvbnQtc2l6ZTog
MTBweDsgcGFkZGluZzogMXB4IDZweDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogOHB4OyBk
aXNwbGF5OiBub25lOyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDJweDsKICAgICAgICAgICAg
dHJhbnNpdGlvbjogY29sb3IgdmFyKC0tdHIpLCBiYWNrZ3JvdW5kIHZhcigtLXRyKTsKICAgICAg
ICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwog
ICAgICAgIH0KICAgICAgICAuaS1leHBhbmQtYnRuLm9uIHsgZGlzcGxheTogaW5saW5lLWZsZXg7
IH0KICAgICAgICAuaS1leHBhbmQtYnRuOmhvdmVyIHsgY29sb3I6IHZhcigtLWFjYyk7IGJhY2tn
cm91bmQ6IHJnYmEoOTEsMTE1LDIzMiwuMDgpOyB9CiAgICAgICAgLmktcHJldi5leHBhbmRlZCwg
LmktbmFtZS5leHBhbmRlZCB7CiAgICAgICAgICAgIC13ZWJraXQtbGluZS1jbGFtcDogdW5zZXQ7
CiAgICAgICAgICAgIG92ZXJmbG93OiB2aXNpYmxlOwogICAgICAgIH0KICAgICAgICAuaS1maWxl
LWRldGFpbCB7CiAgICAgICAgICAgIGRpc3BsYXk6IG5vbmU7CiAgICAgICAgICAgIG1hcmdpbi10
b3A6IDRweDsKICAgICAgICAgICAgcGFkZGluZzogMDsKICAgICAgICAgICAgYmFja2dyb3VuZDog
bm9uZTsKICAgICAgICAgICAgYm9yZGVyOiBub25lOwogICAgICAgIH0KICAgICAgICAuaS1maWxl
LWRldGFpbC5vbiB7IGRpc3BsYXk6IGJsb2NrOyB9CiAgICAgICAgLmZkLWJsb2NrIHsKICAgICAg
ICAgICAgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgZ2FwOiA2cHg7CiAg
ICAgICAgfQogICAgICAgIC5mZC1ibG9jayArIC5mZC1ibG9jayB7IG1hcmdpbi10b3A6IDhweDsg
fQogICAgICAgIC5mZC1wYXRoIHsKICAgICAgICAgICAgd2lkdGg6IDEwMCU7CiAgICAgICAgICAg
IGZvbnQ6IDYwMCAxMnB4LzEuNTUgJ1NlZ29lIFVJIFZhcmlhYmxlIFRleHQnLCdTZWdvZSBVSScs
J01pY3Jvc29mdCBZYUhlaSBVSScsc2Fucy1zZXJpZjsKICAgICAgICAgICAgY29sb3I6IHZhcigt
LXR4dDIpOwogICAgICAgICAgICBsZXR0ZXItc3BhY2luZzogLjAxZW07CiAgICAgICAgICAgIHdv
cmQtYnJlYWs6IGJyZWFrLWFsbDsKICAgICAgICAgICAgdXNlci1zZWxlY3Q6IHRleHQ7CiAgICAg
ICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsK
ICAgICAgICB9CiAgICAgICAgLmZkLXBhdGgubGl2ZSB7IGN1cnNvcjogcG9pbnRlcjsgfQogICAg
ICAgIC5mZC1wYXRoLmxpdmU6aG92ZXIgeyBjb2xvcjogdmFyKC0tYWNjKTsgfQogICAgICAgIC5m
ZC1wYXRoLmRlYWQgewogICAgICAgICAgICBjb2xvcjogIzlhYTBiMDsKICAgICAgICAgICAgdGV4
dC1kZWNvcmF0aW9uOiBsaW5lLXRocm91Z2g7CiAgICAgICAgICAgIHRleHQtZGVjb3JhdGlvbi10
aGlja25lc3M6IDJweDsKICAgICAgICAgICAgdGV4dC1kZWNvcmF0aW9uLWNvbG9yOiByZ2JhKDE1
NCwgMTYwLCAxNzYsIC41NSk7CiAgICAgICAgICAgIHRleHQtZGVjb3JhdGlvbi1za2lwLWluazog
bm9uZTsKICAgICAgICAgICAgY3Vyc29yOiBkZWZhdWx0OwogICAgICAgIH0KICAgICAgICAuZmQt
YWN0aW9ucyB7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7
IGp1c3RpZnktY29udGVudDogZmxleC1lbmQ7CiAgICAgICAgICAgIGdhcDogOHB4OyBmbGV4LXdy
YXA6IHdyYXA7CiAgICAgICAgfQogICAgICAgIC5mZC1idG4gewogICAgICAgICAgICBib3JkZXI6
IG5vbmU7IGJhY2tncm91bmQ6IG5vbmU7IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICAgICAgY29s
b3I6IHZhcigtLXR4dDMpOyBmb250LXNpemU6IDEwcHg7IGZvbnQtd2VpZ2h0OiA2MDA7CiAgICAg
ICAgICAgIHBhZGRpbmc6IDFweCAycHg7IGRpc3BsYXk6IGlubGluZS1mbGV4OyBhbGlnbi1pdGVt
czogY2VudGVyOyBnYXA6IDJweDsKICAgICAgICAgICAgd2hpdGUtc3BhY2U6IG5vd3JhcDsKICAg
ICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFn
OwogICAgICAgICAgICB0cmFuc2l0aW9uOiBjb2xvciB2YXIoLS10cik7CiAgICAgICAgfQogICAg
ICAgIC5mZC1idG46aG92ZXIgeyBjb2xvcjogdmFyKC0tYWNjKTsgfQogICAgICAgIC5mZC1idG4u
b2sgeyBjb2xvcjogIzFmN2E1NTsgfQoKICAgICAgICAvKiDilIDilIAgQ29udGV4dCBtZW51IOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgCAqLwogICAgICAgICNjdHggewog
ICAgICAgICAgICBwb3NpdGlvbjogZml4ZWQ7IHotaW5kZXg6IDk5OTk7IG1pbi13aWR0aDogMTMy
cHg7IGRpc3BsYXk6IG5vbmU7IHBhZGRpbmc6IDRweDsKICAgICAgICAgICAgYmFja2dyb3VuZDog
I2ZmZjsgYm9yZGVyLXJhZGl1czogdmFyKC0tcik7IGJveC1zaGFkb3c6IDAgNnB4IDE2cHggcmdi
YSgwLDAsMCwuMTQpOwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFw
cC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgfQogICAgICAgICNjdHgub24geyBkaXNwbGF5OiBi
bG9jazsgfQogICAgICAgIC5jLWl0ZW0gewogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBhbGln
bi1pdGVtczogY2VudGVyOyBnYXA6IDdweDsgcGFkZGluZzogNnB4IDlweDsKICAgICAgICAgICAg
Ym9yZGVyLXJhZGl1czogdmFyKC0tcik7IGN1cnNvcjogcG9pbnRlcjsgZm9udC1zaXplOiAxMXB4
OyBjb2xvcjogdmFyKC0tdHh0KTsKICAgICAgICB9CiAgICAgICAgLmMtaXRlbTpob3ZlciB7IGJh
Y2tncm91bmQ6ICNmMmY0Zjk7IH0KICAgICAgICAuYy1pdGVtLmRhbmdlciB7IGNvbG9yOiAjZmY3
YjljOyB9CiAgICAgICAgLmMtc2VwIHsgaGVpZ2h0OiAxcHg7IGJhY2tncm91bmQ6ICNlY2VmZjU7
IG1hcmdpbjogM3B4IDA7IH0KICAgICAgICAuYy1pY28geyB3aWR0aDogMTRweDsgdGV4dC1hbGln
bjogY2VudGVyOyB9CgogICAgICAgIC8qIOKUgOKUgCBDbGVhciBjb25maXJtIOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgCAqLwogICAgICAgICNjbHItZGxnIHsKICAgICAgICAg
ICAgZGlzcGxheTogbm9uZTsgcG9zaXRpb246IGZpeGVkOyBpbnNldDogMDsgei1pbmRleDogMTAw
MDA7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoMjAsIDIyLCAzNSwgLjQyKTsKICAgICAg
ICAgICAgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7CiAgICAg
ICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsK
ICAgICAgICB9CiAgICAgICAgI2Nsci1kbGcub24geyBkaXNwbGF5OiBmbGV4OyB9CiAgICAgICAg
LmNsci1ib3ggewogICAgICAgICAgICB3aWR0aDogbWluKDI4MHB4LCBjYWxjKDEwMCUgLSAzMnB4
KSk7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNmZmY7IGJvcmRlci1yYWRpdXM6IDEycHg7CiAg
ICAgICAgICAgIGJveC1zaGFkb3c6IDAgMTJweCAzMnB4IHJnYmEoMCwwLDAsLjE4KTsKICAgICAg
ICAgICAgcGFkZGluZzogMTZweCAxNnB4IDE0cHg7IGNvbG9yOiB2YXIoLS10eHQpOwogICAgICAg
IH0KICAgICAgICAuY2xyLXRpdGxlIHsgZm9udC1zaXplOiAxNHB4OyBmb250LXdlaWdodDogNzAw
OyBtYXJnaW4tYm90dG9tOiA2cHg7IH0KICAgICAgICAuY2xyLWRlc2MgeyBmb250LXNpemU6IDEx
cHg7IGNvbG9yOiB2YXIoLS10eHQzKTsgbGluZS1oZWlnaHQ6IDEuNTsgbWFyZ2luLWJvdHRvbTog
MTJweDsgfQogICAgICAgIC5jbHItY2hlY2sgewogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBh
bGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDdweDsKICAgICAgICAgICAgZm9udC1zaXplOiAxMnB4
OyBjb2xvcjogdmFyKC0tdHh0KTsgY3Vyc29yOiBwb2ludGVyOwogICAgICAgICAgICB1c2VyLXNl
bGVjdDogbm9uZTsgbWFyZ2luLWJvdHRvbTogMTRweDsKICAgICAgICB9CiAgICAgICAgLmNsci1j
aGVjayBpbnB1dCB7CiAgICAgICAgICAgIHdpZHRoOiAxNHB4OyBoZWlnaHQ6IDE0cHg7IGFjY2Vu
dC1jb2xvcjogdmFyKC0tYWNjKTsgY3Vyc29yOiBwb2ludGVyOwogICAgICAgIH0KICAgICAgICAu
Y2xyLWJ0bnMgeyBkaXNwbGF5OiBmbGV4OyBnYXA6IDhweDsganVzdGlmeS1jb250ZW50OiBmbGV4
LWVuZDsgfQogICAgICAgIC5jbHItYnRucyBidXR0b24gewogICAgICAgICAgICBib3JkZXI6IG5v
bmU7IGJvcmRlci1yYWRpdXM6IDhweDsgcGFkZGluZzogN3B4IDE0cHg7CiAgICAgICAgICAgIGZv
bnQtc2l6ZTogMTJweDsgY3Vyc29yOiBwb2ludGVyOyBmb250LXdlaWdodDogNjAwOwogICAgICAg
ICAgICB0cmFuc2l0aW9uOiBiYWNrZ3JvdW5kIHZhcigtLXRyKSwgY29sb3IgdmFyKC0tdHIpOwog
ICAgICAgIH0KICAgICAgICAjY2xyLWNhbmNlbCB7IGJhY2tncm91bmQ6ICNmMWYzZjg7IGNvbG9y
OiB2YXIoLS10eHQyKTsgfQogICAgICAgICNjbHItY2FuY2VsOmhvdmVyIHsgYmFja2dyb3VuZDog
I2U2ZTlmMjsgfQogICAgICAgICNjbHItb2sgeyBiYWNrZ3JvdW5kOiByZ2JhKDI1NSwxMjMsMTU2
LC4xNCk7IGNvbG9yOiAjZTg1YTdhOyB9CiAgICAgICAgI2Nsci1vazpob3ZlciB7IGJhY2tncm91
bmQ6IHJnYmEoMjU1LDEyMywxNTYsLjI0KTsgfQoKICAgICAgICAvKiDilIDilIAgRmlsZSBwYXRo
IHRpcCDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAgKi8KICAgICAgICAjcGF0
aC10aXAgewogICAgICAgICAgICBkaXNwbGF5OiBub25lOyBwb3NpdGlvbjogZml4ZWQ7IHotaW5k
ZXg6IDEwMDAxOwogICAgICAgICAgICB3aWR0aDogbWluKDMyMHB4LCBjYWxjKDEwMHZ3IC0gMTZw
eCkpOwogICAgICAgICAgICBtYXgtaGVpZ2h0OiBtaW4oMjgwcHgsIGNhbGMoMTAwdmggLSAyNHB4
KSk7CiAgICAgICAgICAgIG92ZXJmbG93OiBhdXRvOwogICAgICAgICAgICBwYWRkaW5nOiAwOwog
ICAgICAgICAgICBiYWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGllbnQoMTY1ZGVnLCAjZmZmZmZmIDAl
LCAjZjZmOGZjIDEwMCUpOwogICAgICAgICAgICBib3JkZXI6IDFweCBzb2xpZCByZ2JhKDcwLCA4
NCwgMTIwLCAuMSk7CiAgICAgICAgICAgIGJvcmRlci1yYWRpdXM6IDEycHg7CiAgICAgICAgICAg
IGJveC1zaGFkb3c6CiAgICAgICAgICAgICAgICAwIDRweCA2cHggcmdiYSgzMCwgNDAsIDcwLCAu
MDQpLAogICAgICAgICAgICAgICAgMCAxNHB4IDM2cHggcmdiYSgzMCwgNDAsIDcwLCAuMTYpOwog
ICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0KTsKICAgICAgICAgICAgcG9pbnRlci1ldmVudHM6
IGF1dG87CiAgICAgICAgICAgIG9wYWNpdHk6IDA7CiAgICAgICAgICAgIHRyYW5zZm9ybTogdHJh
bnNsYXRlWSg0cHgpIHNjYWxlKC45OCk7CiAgICAgICAgICAgIHRyYW5zaXRpb246IG9wYWNpdHkg
LjE0cyBlYXNlLCB0cmFuc2Zvcm0gLjE0cyBlYXNlOwogICAgICAgICAgICAtd2Via2l0LWFwcC1y
ZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgfQogICAgICAgICNw
YXRoLXRpcC5vbiB7CiAgICAgICAgICAgIGRpc3BsYXk6IGJsb2NrOwogICAgICAgICAgICBvcGFj
aXR5OiAxOwogICAgICAgICAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoMCkgc2NhbGUoMSk7CiAg
ICAgICAgfQogICAgICAgIC5wdC1oZWFkIHsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgYWxp
Z24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBzcGFjZS1iZXR3ZWVuOwogICAgICAg
ICAgICBnYXA6IDEwcHg7IHBhZGRpbmc6IDEwcHggMTJweCA4cHg7CiAgICAgICAgICAgIGJvcmRl
ci1ib3R0b206IDFweCBzb2xpZCByZ2JhKDcwLCA4NCwgMTIwLCAuMDcpOwogICAgICAgIH0KICAg
ICAgICAucHQtdGl0bGUgewogICAgICAgICAgICBmb250LXNpemU6IDExcHg7IGZvbnQtd2VpZ2h0
OiA3MDA7IGxldHRlci1zcGFjaW5nOiAuMDRlbTsKICAgICAgICAgICAgY29sb3I6IHZhcigtLXR4
dDIpOyB0ZXh0LXRyYW5zZm9ybTogdXBwZXJjYXNlOwogICAgICAgICAgICBmbGV4LXNocmluazog
MDsKICAgICAgICB9CiAgICAgICAgLnB0LWhlYWQtYnRuIHsKICAgICAgICAgICAgZmxleC1zaHJp
bms6IDA7IG1hcmdpbi1sZWZ0OiBhdXRvOwogICAgICAgICAgICBoZWlnaHQ6IDIycHg7IHBhZGRp
bmc6IDAgOHB4OyBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2Fw
OiA0cHg7CiAgICAgICAgICAgIGJvcmRlcjogMXB4IHNvbGlkIHJnYmEoMTA3LDExMiwxMjgsLjIy
KTsgYm9yZGVyLXJhZGl1czogNnB4OyBjdXJzb3I6IHBvaW50ZXI7CiAgICAgICAgICAgIGJhY2tn
cm91bmQ6IHJnYmEoMTA3LDExMiwxMjgsLjA2KTsgY29sb3I6ICM4YTkwYTA7IGZvbnQtc2l6ZTog
MTFweDsgZm9udC13ZWlnaHQ6IDYwMDsKICAgICAgICAgICAgd2hpdGUtc3BhY2U6IG5vd3JhcDsK
ICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1k
cmFnOwogICAgICAgICAgICB0cmFuc2l0aW9uOiBiYWNrZ3JvdW5kIHZhcigtLXRyKSwgY29sb3Ig
dmFyKC0tdHIpLCBib3JkZXItY29sb3IgdmFyKC0tdHIpOwogICAgICAgIH0KICAgICAgICAucHQt
aGVhZC1idG46aG92ZXIgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDEwNywxMTIsMTI4
LC4xMik7IGNvbG9yOiB2YXIoLS10eHQyKTsKICAgICAgICAgICAgYm9yZGVyLWNvbG9yOiByZ2Jh
KDEwNywxMTIsMTI4LC40KTsKICAgICAgICB9CiAgICAgICAgLnB0LWxpc3QgeyBwYWRkaW5nOiA2
cHggOHB4IDhweDsgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgZ2FwOiA0
cHg7IH0KICAgICAgICAucHQtcm93IHsKICAgICAgICAgICAgZGlzcGxheTogZ3JpZDsgZ3JpZC10
ZW1wbGF0ZS1jb2x1bW5zOiA4cHggMWZyOyBnYXA6IDhweDsKICAgICAgICAgICAgcGFkZGluZzog
OHB4IDhweDsgYm9yZGVyLXJhZGl1czogOHB4OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2Jh
KDI1NSwyNTUsMjU1LC43KTsKICAgICAgICB9CiAgICAgICAgLnB0LXJvdy5kZWFkIHsgYmFja2dy
b3VuZDogcmdiYSgyNTUsIDEyMywgMTU2LCAuMDYpOyB9CiAgICAgICAgLnB0LWRvdCB7CiAgICAg
ICAgICAgIHdpZHRoOiA4cHg7IGhlaWdodDogOHB4OyBib3JkZXItcmFkaXVzOiA1MCU7IG1hcmdp
bi10b3A6IDVweDsKICAgICAgICAgICAgYmFja2dyb3VuZDogIzJlYjQ3ODsgYm94LXNoYWRvdzog
MCAwIDAgM3B4IHJnYmEoNDYsIDE4MCwgMTIwLCAuMTgpOwogICAgICAgIH0KICAgICAgICAucHQt
cm93LmRlYWQgLnB0LWRvdCB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNlODVhN2E7IGJveC1z
aGFkb3c6IDAgMCAwIDNweCByZ2JhKDIzMiwgOTAsIDEyMiwgLjE2KTsKICAgICAgICB9CiAgICAg
ICAgLnB0LW5hbWUgewogICAgICAgICAgICBmb250LXNpemU6IDEycHg7IGZvbnQtd2VpZ2h0OiA2
NTA7IGNvbG9yOiB2YXIoLS10eHQpOwogICAgICAgICAgICBsaW5lLWhlaWdodDogMS4zOyB3b3Jk
LWJyZWFrOiBicmVhay1hbGw7CiAgICAgICAgfQogICAgICAgIC5wdC1wYXRoIHsKICAgICAgICAg
ICAgbWFyZ2luLXRvcDogM3B4OwogICAgICAgICAgICBmb250OiAxMC41cHgvMS40NSAnQ2FzY2Fk
aWEgTW9ubycsJ0NvbnNvbGFzJywnTWljcm9zb2Z0IFlhSGVpIFVJJyxtb25vc3BhY2U7CiAgICAg
ICAgICAgIGNvbG9yOiB2YXIoLS10eHQyKTsgd29yZC1icmVhazogYnJlYWstYWxsOwogICAgICAg
ICAgICB1c2VyLXNlbGVjdDogdGV4dDsKICAgICAgICB9CiAgICAgICAgLnB0LXBhdGgubGl2ZSB7
CiAgICAgICAgICAgIGNvbG9yOiB2YXIoLS1hY2MpOyBjdXJzb3I6IHBvaW50ZXI7CiAgICAgICAg
fQogICAgICAgIC5wdC1wYXRoLmxpdmU6aG92ZXIgeyB0ZXh0LWRlY29yYXRpb246IHVuZGVybGlu
ZTsgfQogICAgICAgIC5wdC1wYXRoLmRlYWQgewogICAgICAgICAgICBjb2xvcjogI2M0M2Q1YzsK
ICAgICAgICAgICAgdGV4dC1kZWNvcmF0aW9uOiBsaW5lLXRocm91Z2g7CiAgICAgICAgICAgIHRl
eHQtZGVjb3JhdGlvbi10aGlja25lc3M6IDJweDsKICAgICAgICAgICAgdGV4dC1kZWNvcmF0aW9u
LWNvbG9yOiAjZTExZDQ4OwogICAgICAgICAgICBjdXJzb3I6IGRlZmF1bHQ7CiAgICAgICAgfQog
ICAgICAgIC5wdC1hY3Rpb25zIHsKICAgICAgICAgICAgbWFyZ2luLXRvcDogNnB4OwogICAgICAg
ICAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDZweDsgZmxleC13
cmFwOiB3cmFwOwogICAgICAgIH0KICAgICAgICAucHQtY29weS1idG4gewogICAgICAgICAgICBo
ZWlnaHQ6IDIycHg7IHBhZGRpbmc6IDAgOHB4OyBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24t
aXRlbXM6IGNlbnRlcjsKICAgICAgICAgICAgYm9yZGVyOiAxcHggc29saWQgcmdiYSgxMDcsMTEy
LDEyOCwuMjIpOyBib3JkZXItcmFkaXVzOiA2cHg7IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICAg
ICAgYmFja2dyb3VuZDogcmdiYSgxMDcsMTEyLDEyOCwuMDYpOyBjb2xvcjogIzhhOTBhMDsgZm9u
dC1zaXplOiAxMXB4OyBmb250LXdlaWdodDogNjAwOwogICAgICAgICAgICAtd2Via2l0LWFwcC1y
ZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgICAgIHRyYW5zaXRp
b246IGJhY2tncm91bmQgdmFyKC0tdHIpLCBjb2xvciB2YXIoLS10ciksIGJvcmRlci1jb2xvciB2
YXIoLS10cik7CiAgICAgICAgfQogICAgICAgIC5wdC1jb3B5LWJ0bjpob3ZlciB7CiAgICAgICAg
ICAgIGJhY2tncm91bmQ6IHJnYmEoMTA3LDExMiwxMjgsLjEyKTsgY29sb3I6IHZhcigtLXR4dDIp
OwogICAgICAgICAgICBib3JkZXItY29sb3I6IHJnYmEoMTA3LDExMiwxMjgsLjQpOwogICAgICAg
IH0KICAgICAgICAucHQtY29weS1idG4ub2sgewogICAgICAgICAgICBjb2xvcjogIzFmN2E1NTsg
Ym9yZGVyLWNvbG9yOiByZ2JhKDQ2LCAxODAsIDEyMCwgLjM1KTsKICAgICAgICAgICAgYmFja2dy
b3VuZDogcmdiYSg0NiwgMTgwLCAxMjAsIC4xKTsKICAgICAgICB9CiAgICAgICAgLml0bS5pdC1n
cm91cCB7CiAgICAgICAgICAgIGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47CiAgICAgICAgICAgIGFs
aWduLWl0ZW1zOiBzdHJldGNoOwogICAgICAgICAgICBnYXA6IDA7CiAgICAgICAgICAgIHBhZGRp
bmc6IDZweCA4cHggNHB4OwogICAgICAgICAgICBjdXJzb3I6IGRlZmF1bHQ7CiAgICAgICAgfQog
ICAgICAgIC5pdG0uaXQtZ3JvdXA6aG92ZXIgeyBiYWNrZ3JvdW5kOiB2YXIoLS1jYXJkKTsgfQog
ICAgICAgIC5tZy1oZWFkIHsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6
IGNlbnRlcjsgZ2FwOiA2cHg7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTFweDsgY29sb3I6IHZh
cigtLXR4dDMpOyBmb250LXdlaWdodDogNjAwOwogICAgICAgICAgICBwYWRkaW5nOiAycHggMnB4
IDZweDsgdXNlci1zZWxlY3Q6IG5vbmU7CiAgICAgICAgfQogICAgICAgIC5tZy1oZWFkIC5tZy10
YWcgewogICAgICAgICAgICBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGNlbnRl
cjsKICAgICAgICAgICAgaGVpZ2h0OiAxNnB4OyBwYWRkaW5nOiAwIDZweDsgYm9yZGVyLXJhZGl1
czogOHB4OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDkxLDExNSwyMzIsLjEyKTsgY29s
b3I6IHZhcigtLWFjYyk7IGZvbnQtc2l6ZTogMTBweDsKICAgICAgICB9CiAgICAgICAgLm1nLXJv
dyB7CiAgICAgICAgICAgIHBhZGRpbmc6IDdweCA2cHg7IG1hcmdpbi1ib3R0b206IDNweDsKICAg
ICAgICAgICAgYm9yZGVyLXJhZGl1czogNXB4OyBjdXJzb3I6IHBvaW50ZXI7CiAgICAgICAgICAg
IGJvcmRlcjogMXB4IHNvbGlkIHRyYW5zcGFyZW50OwogICAgICAgICAgICB0cmFuc2l0aW9uOiBi
YWNrZ3JvdW5kIC4xMnMgZWFzZSwgYm9yZGVyLWNvbG9yIC4xMnMgZWFzZTsKICAgICAgICB9CiAg
ICAgICAgLm1nLXJvdzpob3ZlciB7IGJhY2tncm91bmQ6IHZhcigtLWNhcmQtaCk7IH0KICAgICAg
ICAubWctcm93LnNlbCB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNlZGYxZmY7CiAgICAgICAg
ICAgIGJvcmRlci1jb2xvcjogcmdiYSg5MSwxMTUsMjMyLC4zNSk7CiAgICAgICAgICAgIGJveC1z
aGFkb3c6IDAgMCAwIDFweCByZ2JhKDkxLDExNSwyMzIsLjI1KTsKICAgICAgICB9CiAgICAgICAg
Lm1nLXJvdy5tdWx0aSB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNlZWYyZmY7CiAgICAgICAg
ICAgIGJvcmRlci1jb2xvcjogcmdiYSg5MSwxMTUsMjMyLC40NSk7CiAgICAgICAgfQogICAgICAg
IC5tZy10aXRsZSB7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTNweDsgZm9udC13ZWlnaHQ6IDYw
MDsgY29sb3I6IHZhcigtLWFjYyk7CiAgICAgICAgICAgIG1hcmdpbi1ib3R0b206IDJweDsgbGlu
ZS1oZWlnaHQ6IDEuMzU7CiAgICAgICAgICAgIGRpc3BsYXk6IC13ZWJraXQtYm94OyAtd2Via2l0
LWJveC1vcmllbnQ6IHZlcnRpY2FsOyAtd2Via2l0LWxpbmUtY2xhbXA6IDI7CiAgICAgICAgICAg
IG92ZXJmbG93OiBoaWRkZW47IHdvcmQtYnJlYWs6IGJyZWFrLXdvcmQ7CiAgICAgICAgfQogICAg
ICAgIC5tZy1ib2R5IHsKICAgICAgICAgICAgZm9udC1zaXplOiAxMi41cHg7IGZvbnQtd2VpZ2h0
OiA1MDA7IGNvbG9yOiB2YXIoLS10eHQpOwogICAgICAgICAgICB3aGl0ZS1zcGFjZTogcHJlLXdy
YXA7IHdvcmQtYnJlYWs6IGJyZWFrLWFsbDsKICAgICAgICAgICAgZGlzcGxheTogLXdlYmtpdC1i
b3g7IC13ZWJraXQtYm94LW9yaWVudDogdmVydGljYWw7IC13ZWJraXQtbGluZS1jbGFtcDogNDsK
ICAgICAgICAgICAgb3ZlcmZsb3c6IGhpZGRlbjsgbGluZS1oZWlnaHQ6IDEuNDsKICAgICAgICB9
CiAgICAgICAgLm1nLWJvZHkuaW1nIHsgY29sb3I6IHZhcigtLXR4dDIpOyB9CiAgICAgICAgLm1n
LXJvdy10b3AgewogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogZmxleC1z
dGFydDsgZ2FwOiA4cHg7CiAgICAgICAgfQogICAgICAgIC5tZy1yb3ctbWFpbiB7IGZsZXg6IDE7
IG1pbi13aWR0aDogMDsgfQogICAgICAgIC5tZy1zcmMgewogICAgICAgICAgICB3aWR0aDogMThw
eDsgaGVpZ2h0OiAxOHB4OyBmbGV4LXNocmluazogMDsgbWFyZ2luLXRvcDogMnB4OwogICAgICAg
ICAgICBib3JkZXItcmFkaXVzOiAzcHg7IG9iamVjdC1maXQ6IGNvbnRhaW47CiAgICAgICAgICAg
IGJhY2tncm91bmQ6IHJnYmEoMCwwLDAsLjA0KTsKICAgICAgICB9CiAgICAgICAgLmktZmF2LXRp
dGxlIHsKICAgICAgICAgICAgZm9udC1zaXplOiAxM3B4OyBmb250LXdlaWdodDogNjAwOyBjb2xv
cjogdmFyKC0tYWNjKTsKICAgICAgICAgICAgbWFyZ2luOiAwIDAgM3B4OyBsaW5lLWhlaWdodDog
MS4zNTsKICAgICAgICAgICAgZGlzcGxheTogLXdlYmtpdC1ib3g7IC13ZWJraXQtYm94LW9yaWVu
dDogdmVydGljYWw7IC13ZWJraXQtbGluZS1jbGFtcDogMjsKICAgICAgICAgICAgb3ZlcmZsb3c6
IGhpZGRlbjsgd29yZC1icmVhazogYnJlYWstd29yZDsKICAgICAgICB9CiAgICAgICAgI3RpdGxl
LWRsZyB7CiAgICAgICAgICAgIGRpc3BsYXk6IG5vbmU7IHBvc2l0aW9uOiBmaXhlZDsgaW5zZXQ6
IDA7IHotaW5kZXg6IDEwMDsKICAgICAgICAgICAgYmFja2dyb3VuZDogcmdiYSgxNSwxOCwyOCwu
MzUpOwogICAgICAgICAgICBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNl
bnRlcjsKICAgICAgICB9CiAgICAgICAgI3RpdGxlLWRsZy5vbiB7IGRpc3BsYXk6IGZsZXg7IH0K
ICAgICAgICAjdGl0bGUtZGxnIC50aXRsZS1ib3ggewogICAgICAgICAgICB3aWR0aDogMjYwcHg7
IHBhZGRpbmc6IDE2cHggMTZweCAxMnB4OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiB2YXIoLS1j
YXJkKTsgYm9yZGVyLXJhZGl1czogMTBweDsKICAgICAgICAgICAgYm94LXNoYWRvdzogMCA4cHgg
MjhweCByZ2JhKDAsMCwwLC4xOCk7CiAgICAgICAgfQogICAgICAgICN0aXRsZS1pbnB1dCB7CiAg
ICAgICAgICAgIHdpZHRoOiAxMDAlOyBib3gtc2l6aW5nOiBib3JkZXItYm94OyBtYXJnaW46IDhw
eCAwIDEycHg7CiAgICAgICAgICAgIGhlaWdodDogMzJweDsgcGFkZGluZzogMCAxMHB4OyBib3Jk
ZXItcmFkaXVzOiA2cHg7CiAgICAgICAgICAgIGJvcmRlcjogMXB4IHNvbGlkICNkNWRhZTY7IGJh
Y2tncm91bmQ6ICNmZmY7IGNvbG9yOiB2YXIoLS10eHQpOwogICAgICAgICAgICBmb250LXNpemU6
IDEzcHg7IG91dGxpbmU6IG5vbmU7CiAgICAgICAgfQogICAgICAgICN0aXRsZS1pbnB1dDpmb2N1
cyB7IGJvcmRlci1jb2xvcjogdmFyKC0tYWNjKTsgfQoKICAgIAogICAgICAgIC8qIHVpLWdyYXkt
YmctdjEgKi8KICAgICAgICA6cm9vdCB7CiAgICAgICAgICAgIC0tYmc6ICNlNGU3ZWUgIWltcG9y
dGFudDsKICAgICAgICB9CiAgICAgICAgaHRtbCwgYm9keSB7CiAgICAgICAgICAgIGJhY2tncm91
bmQ6ICNlNGU3ZWUgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgI2FwcCB7CiAgICAgICAg
ICAgIGJhY2tncm91bmQ6IGxpbmVhci1ncmFkaWVudCgxODBkZWcsICNlOWVjZjMgMCUsICNlMGU0
ZWMgMTAwJSkgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgI2hkciB7CiAgICAgICAgICAg
IGJhY2tncm91bmQ6ICNlMmU2ZWUgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgI3RhYnMg
ewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZTJlNmVlICFpbXBvcnRhbnQ7CiAgICAgICAgfQog
ICAgICAgICNsaXN0LCAjZW1wdHksICNza2VsLCAjaGRyLWdyb3csICNzZWFyY2gtd3JhcCB7CiAg
ICAgICAgICAgIGJhY2tncm91bmQ6IHRyYW5zcGFyZW50ICFpbXBvcnRhbnQ7CiAgICAgICAgfQog
ICAgICAgICNzZWFyY2gtYm94IHsKICAgICAgICAgICAgdHJhbnNmb3JtLW9yaWdpbjogcmlnaHQg
Y2VudGVyOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudCAhaW1wb3J0YW50Owog
ICAgICAgIH0KICAgICAgICAuaXRtLCAubWcsIC5tZy1yb3csIC5tZXJnZS1ncm91cCB7CiAgICAg
ICAgICAgIGJhY2tncm91bmQ6ICNmZmZmZmYgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAg
Lml0bTpob3ZlciB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNmOGY5ZmMgIWltcG9ydGFudDsK
ICAgICAgICB9CiAgICAKICAgICAgICAvKiBzZWwtdGludC1ibHVlLXYxICovCiAgICAgICAgLml0
bS5zZWwsCiAgICAgICAgLm1nLXJvdy5zZWwsCiAgICAgICAgLml0bS5tdWx0aSwKICAgICAgICAu
bWctcm93Lm11bHRpLAogICAgICAgIC5pdG0ubXVsdGkuc2VsLAogICAgICAgIC5pdC1ncm91cC5z
ZWwsCiAgICAgICAgLml0LWdyb3VwLm11bHRpIHsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2U4
ZWZmZiAhaW1wb3J0YW50OwogICAgICAgIH0KICAgICAgICAuaXRtLnNlbDpob3ZlciwKICAgICAg
ICAuaXRtLm11bHRpOmhvdmVyLAogICAgICAgIC5tZy1yb3cuc2VsOmhvdmVyLAogICAgICAgIC5t
Zy1yb3cubXVsdGk6aG92ZXIgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZGRlNmZmICFpbXBv
cnRhbnQ7CiAgICAgICAgfQogICAgCiAgICAgICAgLyogaG92ZXItZ3JlZW4tcmlzZS12MiAqLwog
ICAgICAgIC8qIGhvdmVyLWFjY2VudC1yaXNlLXYzICovCiAgICAgICAgLml0bSB7IHBvc2l0aW9u
OiByZWxhdGl2ZSAhaW1wb3J0YW50OyBvdmVyZmxvdzogaGlkZGVuICFpbXBvcnRhbnQ7IH0KICAg
ICAgICAuaXRtOjpiZWZvcmUgewogICAgICAgICAgICBjb250ZW50OiAiIiAhaW1wb3J0YW50Owog
ICAgICAgICAgICBwb3NpdGlvbjogYWJzb2x1dGUgIWltcG9ydGFudDsKICAgICAgICAgICAgbGVm
dDogMCAhaW1wb3J0YW50OyByaWdodDogMCAhaW1wb3J0YW50OyBib3R0b206IDAgIWltcG9ydGFu
dDsKICAgICAgICAgICAgaGVpZ2h0OiAwICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIHBvaW50ZXIt
ZXZlbnRzOiBub25lICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIHotaW5kZXg6IDAgIWltcG9ydGFu
dDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogMCAwIHZhcigtLXIsIDRweCkgdmFyKC0tciwg
NHB4KSAhaW1wb3J0YW50OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGllbnQo
dG8gdG9wLAogICAgICAgICAgICAgICAgcmdiYSg5MSwgMTE1LCAyMzIsIC4zMikgMCUsCiAgICAg
ICAgICAgICAgICByZ2JhKDkxLCAxMTUsIDIzMiwgLjEyKSA1NSUsCiAgICAgICAgICAgICAgICBy
Z2JhKDkxLCAxMTUsIDIzMiwgMCkgMTAwJSkgIWltcG9ydGFudDsKICAgICAgICAgICAgdHJhbnNp
dGlvbjogaGVpZ2h0IC4zNHMgY3ViaWMtYmV6aWVyKC4yMiwgMSwgLjM2LCAxKSAhaW1wb3J0YW50
OwogICAgICAgIH0KICAgICAgICAuaXRtOmhvdmVyOjpiZWZvcmUgeyBoZWlnaHQ6IDMzLjMzMyUg
IWltcG9ydGFudDsgfQogICAgICAgIC5pdG06OmFmdGVyIHsKICAgICAgICAgICAgY29udGVudDog
IiIgIWltcG9ydGFudDsKICAgICAgICAgICAgcG9zaXRpb246IGFic29sdXRlICFpbXBvcnRhbnQ7
CiAgICAgICAgICAgIGxlZnQ6IDAgIWltcG9ydGFudDsgcmlnaHQ6IDAgIWltcG9ydGFudDsgYm90
dG9tOiAwICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIGhlaWdodDogMnB4ICFpbXBvcnRhbnQ7CiAg
ICAgICAgICAgIHBvaW50ZXItZXZlbnRzOiBub25lICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIHot
aW5kZXg6IDEgIWltcG9ydGFudDsKICAgICAgICAgICAgYmFja2dyb3VuZDogcmdiYSg5MSwgMTE1
LCAyMzIsIC45MikgIWltcG9ydGFudDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogMXB4ICFp
bXBvcnRhbnQ7CiAgICAgICAgICAgIHRyYW5zZm9ybTogc2NhbGVYKDApICFpbXBvcnRhbnQ7CiAg
ICAgICAgICAgIHRyYW5zZm9ybS1vcmlnaW46IGNlbnRlciAhaW1wb3J0YW50OwogICAgICAgICAg
ICB0cmFuc2l0aW9uOiB0cmFuc2Zvcm0gLjNzIGN1YmljLWJlemllciguMjIsIDEsIC4zNiwgMSkg
IWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgLml0bTpob3Zlcjo6YWZ0ZXIgewogICAgICAg
ICAgICB0cmFuc2Zvcm06IHNjYWxlWCgxKSAhaW1wb3J0YW50OwogICAgICAgICAgICBiYWNrZ3Jv
dW5kOiByZ2JhKDkxLCAxMTUsIDIzMiwgLjk1KSAhaW1wb3J0YW50OwogICAgICAgIH0KICAgICAg
ICAuaXRtID4gKiB7IHBvc2l0aW9uOiByZWxhdGl2ZTsgei1pbmRleDogMjsgfQogICAgICAgICAg
ICAvKiB3aGl0ZS1wYW5lbC1ib3JkZXI6IG91dGVyIGVkZ2UgbGluZSByZW1vdmVkICovCiAgICAg
ICAgI2FwcCB7CiAgICAgICAgICAgIGJvcmRlcjogbm9uZSAhaW1wb3J0YW50OwogICAgICAgICAg
ICBib3JkZXItcmFkaXVzOiAwICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIGJveC1zaXppbmc6IGJv
cmRlci1ib3ggIWltcG9ydGFudDsKICAgICAgICAgICAgb3ZlcmZsb3c6IGhpZGRlbiAhaW1wb3J0
YW50OwogICAgICAgIH0KICAgICAgICAuaXRtLCAubWcsIC5tZy1yb3csIC5tZXJnZS1ncm91cCB7
CiAgICAgICAgICAgIGJvcmRlcjogMXB4IHNvbGlkICNmZmZmZmYgIWltcG9ydGFudDsKICAgICAg
ICB9CiAgICA8L3N0eWxlPgo8L2hlYWQ+Cjxib2R5Pgo8ZGl2IGlkPSJhcHAiIGNsYXNzPSJib290
LWxvYWRpbmciPgogICAgPGRpdiBpZD0iaGRyIj4KICAgICAgICA8ZGl2IGlkPSJoZWFydCI+CiAg
ICAgICAgICAgIDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1
cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiCiAgICAgICAgICAgICAgICAgc3Ryb2tlLWxp
bmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIj4KICAgICAgICAgICAgICAgIDxy
ZWN0IHg9IjkiIHk9IjIiIHdpZHRoPSI2IiBoZWlnaHQ9IjQiIHJ4PSIxIi8+CiAgICAgICAgICAg
ICAgICA8cGF0aCBkPSJNMTYgNGgyYTIgMiAwIDAgMSAyIDJ2MTRhMiAyIDAgMCAxLTIgMkg2YTIg
MiAwIDAgMS0yLTJWNmEyIDIgMCAwIDEgMi0yaDIiLz4KICAgICAgICAgICAgICAgIDxwYXRoIGQ9
Ik05IDEyaDZNOSAxNmg0Ii8+CiAgICAgICAgICAgIDwvc3ZnPgogICAgICAgIDwvZGl2PgogICAg
ICAgIDxkaXYgaWQ9Imhkci1ncm93Ij48L2Rpdj4KICAgICAgICA8YnV0dG9uIGlkPSJidG4tbG9j
YXRlIiB0eXBlPSJidXR0b24iIHRpdGxlPSLlrprkvY3liLDkuIrmrKHkvb/nlKjnmoTmnaHnm64i
IGRpc2FibGVkPgogICAgICAgICAgICA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9u
ZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMiIKICAgICAgICAgICAgICAg
ICBzdHJva2UtbGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9pbj0icm91bmQiPgogICAgICAg
ICAgICAgICAgPGNpcmNsZSBjeD0iMTIiIGN5PSIxMiIgcj0iOCIvPgogICAgICAgICAgICAgICAg
PGNpcmNsZSBjeD0iMTIiIGN5PSIxMiIgcj0iMy41Ii8+CiAgICAgICAgICAgIDwvc3ZnPgogICAg
ICAgIDwvYnV0dG9uPgogICAgICAgIDxkaXYgaWQ9InNlYXJjaC13cmFwIj4KICAgICAgICAgICAg
PGJ1dHRvbiBpZD0iYnRuLXNlYXJjaCIgdHlwZT0iYnV0dG9uIiB0aXRsZT0i5pCc57SiIj4KICAg
ICAgICAgICAgICAgIDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9
ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyIgogICAgICAgICAgICAgICAgICAgICBzdHJv
a2UtbGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9pbj0icm91bmQiPgogICAgICAgICAgICAg
ICAgICAgIDxjaXJjbGUgY3g9IjExIiBjeT0iMTEiIHI9IjciLz4KICAgICAgICAgICAgICAgICAg
ICA8cGF0aCBkPSJNMjAgMjBsLTMuNS0zLjUiLz4KICAgICAgICAgICAgICAgIDwvc3ZnPgogICAg
ICAgICAgICA8L2J1dHRvbj4KICAgICAgICAgICAgPGRpdiBpZD0ic2VhcmNoLWJveCI+CiAgICAg
ICAgICAgICAgICA8YnV0dG9uIGlkPSJidG4tdG9kYXkiIHR5cGU9ImJ1dHRvbiI+5b2T5aSpPC9i
dXR0b24+CiAgICAgICAgICAgICAgICA8aW5wdXQgaWQ9InNlYXJjaCIgdHlwZT0idGV4dCIgcGxh
Y2Vob2xkZXI9IuaQnOe0oui/kTEw5aSp4oCmIGF8YiDlkIzml7blkKsiIGF1dG9jb21wbGV0ZT0i
b2ZmIiBzcGVsbGNoZWNrPSJmYWxzZSI+CiAgICAgICAgICAgICAgICA8YnV0dG9uIGlkPSJzZWFy
Y2gtY2xyIiB0eXBlPSJidXR0b24iPuKclTwvYnV0dG9uPgogICAgICAgICAgICA8L2Rpdj4KICAg
ICAgICA8L2Rpdj4KICAgICAgICA8YnV0dG9uIGlkPSJidG4tcGluIiB0eXBlPSJidXR0b24iIHRp
dGxlPSLpkonlnKjlsY/luZXkuIoiPgogICAgICAgICAgICA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAy
NCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMiIKICAg
ICAgICAgICAgICAgICBzdHJva2UtbGluZWpvaW49InJvdW5kIiBzdHJva2UtbGluZWNhcD0icm91
bmQiPgogICAgICAgICAgICAgICAgPGxpbmUgeDE9IjEyIiB5MT0iMTciIHgyPSIxMiIgeTI9IjIy
Ii8+CiAgICAgICAgICAgICAgICA8cGF0aCBkPSJNNSAxN2gxNHYtMS43NmEyIDIgMCAwIDAtMS4x
MS0xLjc5bC0xLjc4LS45QTIgMiAwIDAgMSAxNSAxMC43NlY2aDFhMiAyIDAgMCAwIDAtNEg4YTIg
MiAwIDAgMCAwIDRoMXY0Ljc2YTIgMiAwIDAgMS0xLjExIDEuNzlsLTEuNzguOUEyIDIgMCAwIDAg
NSAxNS4yNFoiLz4KICAgICAgICAgICAgPC9zdmc+CiAgICAgICAgPC9idXR0b24+CiAgICA8L2Rp
dj4KCiAgICA8ZGl2IGlkPSJ0YWJzIj4KICAgICAgICA8ZGl2IGlkPSJ0YWItaW5rIiBhcmlhLWhp
ZGRlbj0idHJ1ZSI+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0idGFiIG9uIiBkYXRhLXRhYj0i
YWxsIj7lhajpg6g8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJ0YWIiIGRhdGEtdGFiPSJ0ZXh0
Ij7mlofmnKw8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJ0YWIiIGRhdGEtdGFiPSJpbWFnZSI+
5Zu+5YOPPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0idGFiIiBkYXRhLXRhYj0iZmlsZSI+5paH
5Lu2PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0idGFiIiBkYXRhLXRhYj0icGlubmVkIj7mlLbo
l48gPHNwYW4gY2xhc3M9ImJhZGdlIiBpZD0icGluLWNudCIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+
MDwvc3Bhbj48L2Rpdj4KICAgICAgICA8ZGl2IGlkPSJ0YWItYWN0aW9ucyI+CiAgICAgICAgICAg
IDxidXR0b24gaWQ9Im11bHRpLWNudCIgdHlwZT0iYnV0dG9uIiB0aXRsZT0i5Y+W5raI5aSa6YCJ
Ij7lt7LpgIkgMDwvYnV0dG9uPgogICAgICAgICAgICA8c3BhbiBpZD0iYmFyLXR4dCI+MDwvc3Bh
bj4KICAgICAgICAgICAgPGJ1dHRvbiBpZD0iYnRuLWNsciIgdHlwZT0iYnV0dG9uIiB0aXRsZT0i
5riF56m65Y6G5Y+yIj4KICAgICAgICAgICAgICAgIDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBm
aWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyIgogICAgICAg
ICAgICAgICAgICAgICBzdHJva2UtbGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9pbj0icm91
bmQiPgogICAgICAgICAgICAgICAgICAgIDxwb2x5bGluZSBwb2ludHM9IjMgNiA1IDYgMjEgNiIv
PgogICAgICAgICAgICAgICAgICAgIDxwYXRoIGQ9Ik0xOSA2bC0xIDE0YTIgMiAwIDAgMS0yIDJI
OGEyIDIgMCAwIDEtMi0yTDUgNiIvPgogICAgICAgICAgICAgICAgICAgIDxwYXRoIGQ9Ik0xMCAx
MXY2TTE0IDExdjZNOSA2VjRoNnYyIi8+CiAgICAgICAgICAgICAgICA8L3N2Zz4KICAgICAgICAg
ICAgPC9idXR0b24+CiAgICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8ZGl2IGlkPSJsaXN0
Ij4KICAgICAgICA8ZGl2IGlkPSJza2VsIiBjbGFzcz0ib24iIGFyaWEtaGlkZGVuPSJ0cnVlIj4K
ICAgICAgICAgICAgPGRpdiBjbGFzcz0ic2stcm93Ij48ZGl2IGNsYXNzPSJzay1pY28iPjwvZGl2
PjxkaXYgY2xhc3M9InNrLWJvZHkiPjxkaXYgY2xhc3M9InNrLWxpbmUgbWlkIj48L2Rpdj48ZGl2
IGNsYXNzPSJzay1saW5lIHNob3J0Ij48L2Rpdj48L2Rpdj48L2Rpdj4KICAgICAgICAgICAgPGRp
diBjbGFzcz0ic2stcm93Ij48ZGl2IGNsYXNzPSJzay1pY28iPjwvZGl2PjxkaXYgY2xhc3M9InNr
LWJvZHkiPjxkaXYgY2xhc3M9InNrLWxpbmUiPjwvZGl2PjxkaXYgY2xhc3M9InNrLWxpbmUgbWlk
Ij48L2Rpdj48L2Rpdj48L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0ic2stcm93Ij48ZGl2
IGNsYXNzPSJzay1pY28iPjwvZGl2PjxkaXYgY2xhc3M9InNrLWJvZHkiPjxkaXYgY2xhc3M9InNr
LWxpbmUgbWlkIj48L2Rpdj48ZGl2IGNsYXNzPSJzay1saW5lIHNob3J0Ij48L2Rpdj48L2Rpdj48
L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0ic2stcm93Ij48ZGl2IGNsYXNzPSJzay1pY28i
PjwvZGl2PjxkaXYgY2xhc3M9InNrLWJvZHkiPjxkaXYgY2xhc3M9InNrLWxpbmUiPjwvZGl2Pjxk
aXYgY2xhc3M9InNrLWxpbmUgbWlkIj48L2Rpdj48L2Rpdj48L2Rpdj4KICAgICAgICAgICAgPGRp
diBjbGFzcz0ic2stcm93Ij48ZGl2IGNsYXNzPSJzay1pY28iPjwvZGl2PjxkaXYgY2xhc3M9InNr
LWJvZHkiPjxkaXYgY2xhc3M9InNrLWxpbmUgbWlkIj48L2Rpdj48ZGl2IGNsYXNzPSJzay1saW5l
IHNob3J0Ij48L2Rpdj48L2Rpdj48L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0ic2stcm93
Ij48ZGl2IGNsYXNzPSJzay1pY28iPjwvZGl2PjxkaXYgY2xhc3M9InNrLWJvZHkiPjxkaXYgY2xh
c3M9InNrLWxpbmUiPjwvZGl2PjxkaXYgY2xhc3M9InNrLWxpbmUgc2hvcnQiPjwvZGl2PjwvZGl2
PjwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgaWQ9ImVtcHR5Ij4KICAgICAgICAg
ICAgPGRpdiBjbGFzcz0iZS10eHQiIGlkPSJlbXB0eS10eHQiPuaaguaXoOiusOW9le+8jOWkjeWI
tuWQjuiHquWKqOWHuueOsDwvZGl2PgogICAgICAgIDwvZGl2PgogICAgPC9kaXY+CiAgICA8YnV0
dG9uIGlkPSJidG4tdG9wIiB0eXBlPSJidXR0b24iIHRpdGxlPSLlm57liLDpobbpg6giIGFyaWEt
bGFiZWw9IuWbnuWIsOmhtumDqCI+CiAgICAgICAgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZp
bGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIuMiIKICAgICAg
ICAgICAgIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI+CiAg
ICAgICAgICAgIDxwYXRoIGQ9Ik0xMiAxOVY1Ii8+CiAgICAgICAgICAgIDxwYXRoIGQ9Ik01IDEy
bDctNyA3IDciLz4KICAgICAgICA8L3N2Zz4KICAgIDwvYnV0dG9uPgo8L2Rpdj4KCjxkaXYgaWQ9
ImN0eCI+CiAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0iIGlkPSJjLWNvcHkiPjxzcGFuIGNsYXNzPSJj
LWljbyI+4o6YPC9zcGFuPuWkjeWItjwvZGl2PgogICAgPGRpdiBjbGFzcz0iYy1pdGVtIiBpZD0i
Yy1wYXN0ZSI+PHNwYW4gY2xhc3M9ImMtaWNvIj7ij448L3NwYW4+57KY6LS0PC9kaXY+CiAgICA8
ZGl2IGNsYXNzPSJjLXNlcCI+PC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0iIGlkPSJjLXBp
biI+PHNwYW4gY2xhc3M9ImMtaWNvIj7imIU8L3NwYW4+5pS26JePPC9kaXY+CiAgICA8ZGl2IGNs
YXNzPSJjLWl0ZW0iIGlkPSJjLXRpdGxlIiBzdHlsZT0iZGlzcGxheTpub25lIj48c3BhbiBjbGFz
cz0iYy1pY28iPuKcjjwvc3Bhbj7orr7nva7moIfpopg8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImMt
aXRlbSIgaWQ9ImMtbWVyZ2UiIHN0eWxlPSJkaXNwbGF5Om5vbmUiPjxzcGFuIGNsYXNzPSJjLWlj
byI+4qeJPC9zcGFuPuWQiOW5tjwvZGl2PgogICAgPGRpdiBjbGFzcz0iYy1pdGVtIiBpZD0iYy11
bm1lcmdlIiBzdHlsZT0iZGlzcGxheTpub25lIj48c3BhbiBjbGFzcz0iYy1pY28iPuKHhDwvc3Bh
bj7lj5bmtojlkIjlubY8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImMtaXRlbSIgaWQ9ImMtdG9wIj48
c3BhbiBjbGFzcz0iYy1pY28iPuKGkTwvc3Bhbj7np7vliLDpobbpg6g8L2Rpdj4KICAgIDxkaXYg
Y2xhc3M9ImMtaXRlbSIgaWQ9ImMtY2xlYXItcGFzdGVkIiBzdHlsZT0iZGlzcGxheTpub25lIj48
c3BhbiBjbGFzcz0iYy1pY28iPuKckzwvc3Bhbj7muIXpmaTnirbmgIE8L2Rpdj4KICAgIDxkaXYg
Y2xhc3M9ImMtc2VwIj48L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImMtaXRlbSBkYW5nZXIiIGlkPSJj
LWRlbCI+PHNwYW4gY2xhc3M9ImMtaWNvIj7inJU8L3NwYW4+5Yig6ZmkPC9kaXY+CjwvZGl2PgoK
PGRpdiBpZD0iY2xyLWRsZyI+CiAgICA8ZGl2IGNsYXNzPSJjbHItYm94IiByb2xlPSJkaWFsb2ci
IGFyaWEtbW9kYWw9InRydWUiPgogICAgICAgIDxkaXYgY2xhc3M9ImNsci10aXRsZSIgaWQ9ImNs
ci10aXRsZSI+56Gu6K6k5riF56m677yfPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iY2xyLWRl
c2MiIGlkPSJjbHItZGVzYyI+6buY6K6k5LuF5riF56m65b2T5aSp5YaF5a6544CCPC9kaXY+CiAg
ICAgICAgPGxhYmVsIGNsYXNzPSJjbHItY2hlY2siIGZvcj0iY2xyLWFsbCI+CiAgICAgICAgICAg
IDxpbnB1dCB0eXBlPSJjaGVja2JveCIgaWQ9ImNsci1hbGwiPgogICAgICAgICAgICA8c3Bhbj7m
uIXnqbrmiYDmnIk8L3NwYW4+CiAgICAgICAgPC9sYWJlbD4KICAgICAgICA8ZGl2IGNsYXNzPSJj
bHItYnRucyI+CiAgICAgICAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBpZD0iY2xyLWNhbmNl
bCI+5Y+W5raIPC9idXR0b24+CiAgICAgICAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBpZD0i
Y2xyLW9rIj7muIXnqbo8L2J1dHRvbj4KICAgICAgICA8L2Rpdj4KICAgIDwvZGl2Pgo8L2Rpdj4K
CjxkaXYgaWQ9InRpdGxlLWRsZyI+CiAgICA8ZGl2IGNsYXNzPSJ0aXRsZS1ib3giIHJvbGU9ImRp
YWxvZyIgYXJpYS1tb2RhbD0idHJ1ZSI+CiAgICAgICAgPGRpdiBjbGFzcz0iY2xyLXRpdGxlIj7o
rr7nva7moIfpopg8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJjbHItZGVzYyI+5qCH6aKY5Y+v
6KKr5pCc57Si5om+5Yiw77yM5LuF55So5LqO5pS26JeP5pW055CG44CCPC9kaXY+CiAgICAgICAg
PGlucHV0IGlkPSJ0aXRsZS1pbnB1dCIgdHlwZT0idGV4dCIgbWF4bGVuZ3RoPSI4MCIgcGxhY2Vo
b2xkZXI9Iue7mei/meadoeaUtuiXj+i1t+S4quWQjeWtl+KApiIgYXV0b2NvbXBsZXRlPSJvZmYi
IHNwZWxsY2hlY2s9ImZhbHNlIj4KICAgICAgICA8ZGl2IGNsYXNzPSJjbHItYnRucyI+CiAgICAg
ICAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBpZD0idGl0bGUtY2FuY2VsIj7lj5bmtog8L2J1
dHRvbj4KICAgICAgICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGlkPSJ0aXRsZS1vayI+5L+d
5a2YPC9idXR0b24+CiAgICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KPC9kaXY+CjxkaXYgaWQ9InBh
dGgtdGlwIiBhcmlhLWhpZGRlbj0idHJ1ZSI+PC9kaXY+Cgo8c2NyaXB0PgovKiBza2VsLWZhaWxz
YWZlOiBvbmx5IGlmIG1haW4gVUkgc2NyaXB0IG5ldmVyIGJvb3RlZCAqLwooZnVuY3Rpb24oKXsK
ICBzZXRUaW1lb3V0KCgpID0+IHsKICAgIHRyeSB7CiAgICAgIGlmICh3aW5kb3cuX191aUJvb3Rl
ZCkgcmV0dXJuOwogICAgICB2YXIgcyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdza2VsJyk7
CiAgICAgIGlmIChzKSBzLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgIHZhciBlID0gZG9j
dW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2VtcHR5Jyk7CiAgICAgIGlmIChlICYmICFkb2N1bWVudC5x
dWVyeVNlbGVjdG9yKCcjbGlzdCAuaXRtJykpIGUuY2xhc3NMaXN0LmFkZCgnb24nKTsKICAgIH0g
Y2F0Y2ggKGVycikge30KICB9LCAzMDAwKTsKfSkoKTsKPC9zY3JpcHQ+CjxzY3JpcHQ+CiAgICBs
ZXQgYWxsQ2xpcHMgPSBbXSwgY3VyVGFiID0gJ2FsbCcsIHF1ZXJ5ID0gJycsIGN0eENsaXAgPSBu
dWxsLCBzZWxlY3RlZElkID0gMCwgcGlubmVkVUkgPSBmYWxzZTsKICAgIGNvbnN0IFRBQl9PUkRF
UiA9IFsnYWxsJywgJ3RleHQnLCAnaW1hZ2UnLCAnZmlsZScsICdwaW5uZWQnXTsKICAgIGxldCB0
YWJTd2l0Y2hBbmltRGlyID0gMDsKICAgIGxldCBtdWx0aUlkcyA9IFtdOwogICAgbGV0IHRvZGF5
T25seSA9IGZhbHNlOwogICAgbGV0IGRpc2tUb3RhbCA9IDA7CiAgICBsZXQgbG9hZGluZ01vcmUg
PSBmYWxzZTsKICAgIGxldCBib290TG9hZGluZyA9IHRydWU7CiAgICB3aW5kb3cuX19kYXRhUmVh
ZHkgPSBmYWxzZTsKICAgIHdpbmRvdy5fX3VpQm9vdGVkID0gdHJ1ZTsKICAgIC8vIE9wZW4gcGFu
ZWwgd2l0aG91dCBwYXN0aW5nIOKGkiBhbHdheXMgbGFuZCBvbiBmaXJzdCBpdGVtIChhZnRlciBk
YXRhIGFycml2ZXMpCiAgICBsZXQgc2VsZWN0Rmlyc3RPblNob3cgPSBmYWxzZTsKICAgIGxldCBs
YXN0UGFzdGVJZCA9IDA7CiAgICBsZXQgbGFzdFBhc3RlVGFiID0gJ2FsbCc7CiAgICBsZXQgbG9j
YXRlQWN0aXZlID0gZmFsc2U7CiAgICB0cnkgeyBsYXN0UGFzdGVJZCA9ICtsb2NhbFN0b3JhZ2Uu
Z2V0SXRlbSgnY2xpcExhc3RQYXN0ZUlkJykgfHwgMDsgfSBjYXRjaCB7fQogICAgdHJ5IHsKICAg
ICAgICBjb25zdCB0ID0gbG9jYWxTdG9yYWdlLmdldEl0ZW0oJ2NsaXBMYXN0UGFzdGVUYWInKSB8
fCAnYWxsJzsKICAgICAgICBsYXN0UGFzdGVUYWIgPSBbJ2FsbCcsJ3RleHQnLCdpbWFnZScsJ2Zp
bGUnLCdwaW5uZWQnXS5pbmNsdWRlcyh0KSA/IHQgOiAnYWxsJzsKICAgIH0gY2F0Y2gge30KICAg
IC8vIFNhbWUtb3JpZ2luIHVuZGVyIGNsaXB1aS5sb2NhbCAoQVBQX0hPU1Qg4oaSIENMSVBfVjFf
RElSKS4gQ3Jvc3MtaG9zdCBjbGlwcy5zdG9yZSBpcyB1bnJlbGlhYmxlLgogICAgY29uc3QgU1RP
UkVfQkFTRSA9IChsb2NhdGlvbi5vcmlnaW4gJiYgbG9jYXRpb24ub3JpZ2luLmluZGV4T2YoJ2h0
dHBzOi8vJykgPT09IDApCiAgICAgICAgPyAobG9jYXRpb24ub3JpZ2luLnJlcGxhY2UoL1wvJC8s
ICcnKSArICcvY2xpcHNfc3RvcmUvJykKICAgICAgICA6ICdodHRwczovL2NsaXB1aS5sb2NhbC9j
bGlwc19zdG9yZS8nOwogICAgZnVuY3Rpb24gbWV0YUNlbnRlckh0bWwoZXhwYW5kSW5uZXIpIHsK
ICAgICAgICBpZiAoZXhwYW5kSW5uZXIgPT0gbnVsbCB8fCBleHBhbmRJbm5lciA9PT0gZmFsc2Up
CiAgICAgICAgICAgIHJldHVybiBgPHNwYW4gY2xhc3M9ImktbWV0YS1jZW50ZXIiPjwvc3Bhbj5g
OwogICAgICAgIHJldHVybiBgPHNwYW4gY2xhc3M9ImktbWV0YS1jZW50ZXIiPjxidXR0b24gY2xh
c3M9ImktZXhwYW5kLWJ0biR7ZXhwYW5kSW5uZXIub24gPyAnIG9uJyA6ICcnfSIgdHlwZT0iYnV0
dG9uIiB0aXRsZT0i5bGV5byAL+aUtui1tyI+JHtleHBhbmRJbm5lci5odG1sfTwvYnV0dG9uPjwv
c3Bhbj5gOwogICAgfQoKICAgIGZ1bmN0aW9uIHJlbWVtYmVyTGFzdFBhc3RlKGlkKSB7CiAgICAg
ICAgbGFzdFBhc3RlSWQgPSAraWQgfHwgMDsKICAgICAgICBsYXN0UGFzdGVUYWIgPSBjdXJUYWIg
fHwgJ2FsbCc7CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgbG9jYWxTdG9yYWdlLnNldEl0ZW0o
J2NsaXBMYXN0UGFzdGVJZCcsIFN0cmluZyhsYXN0UGFzdGVJZCkpOwogICAgICAgICAgICBsb2Nh
bFN0b3JhZ2Uuc2V0SXRlbSgnY2xpcExhc3RQYXN0ZVRhYicsIGxhc3RQYXN0ZVRhYik7CiAgICAg
ICAgfSBjYXRjaCB7fQogICAgICAgIHVwZGF0ZUxvY2F0ZUJ0bigpOwogICAgfQogICAgZnVuY3Rp
b24gdXBkYXRlTG9jYXRlQnRuKCkgewogICAgICAgIGNvbnN0IGJ0biA9IGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCdidG4tbG9jYXRlJyk7CiAgICAgICAgaWYgKCFidG4pIHJldHVybjsKICAgICAg
ICBidG4uZGlzYWJsZWQgPSAhbGFzdFBhc3RlSWQ7CiAgICAgICAgYnRuLmNsYXNzTGlzdC50b2dn
bGUoJ2hhcy10YXJnZXQnLCAhIWxhc3RQYXN0ZUlkKTsKICAgICAgICBidG4uY2xhc3NMaXN0LnRv
Z2dsZSgnb24nLCBsb2NhdGVBY3RpdmUgJiYgISFsYXN0UGFzdGVJZCk7CiAgICAgICAgYnRuLnRp
dGxlID0gIWxhc3RQYXN0ZUlkCiAgICAgICAgICAgID8gJ+aaguaXoOS4iuasoeS9v+eUqOS9jee9
ricKICAgICAgICAgICAgOiAobG9jYXRlQWN0aXZlID8gJ+WPlua2iOWumuS9je+8jOWbnuWIsOes
rOS4gOadoScgOiAn5a6a5L2N5Yiw5LiK5qyh5L2/55So55qE5p2h55uuJyk7CiAgICB9CiAgICBm
dW5jdGlvbiBzZWxlY3RGaXJzdEl0ZW0oKSB7CiAgICAgICAgbG9jYXRlQWN0aXZlID0gZmFsc2U7
CiAgICAgICAgd2luZG93Ll9fcGVuZGluZ0p1bXBJZCA9IDA7CiAgICAgICAgd2luZG93Ll9fanVt
cExvYWRUcmllcyA9IDA7CiAgICAgICAgc2VsZWN0Rmlyc3RPblNob3cgPSBmYWxzZTsKICAgICAg
ICBjb25zdCB2aXMgPSB2aXNpYmxlTGlzdCgpOwogICAgICAgIGlmICghdmlzLmxlbmd0aCkgewog
ICAgICAgICAgICBzZWxlY3RlZElkID0gMDsKICAgICAgICAgICAgc3luY0l0ZW1IaWdobGlnaHQo
KTsKICAgICAgICAgICAgdXBkYXRlTG9jYXRlQnRuKCk7CiAgICAgICAgICAgIHJldHVybjsKICAg
ICAgICB9CiAgICAgICAgc2VsZWN0ZWRJZCA9IHZpc1swXS5pZDsKICAgICAgICByYW5nZUFuY2hv
cklkID0gc2VsZWN0ZWRJZDsKICAgICAgICByYW5nZUFuY2hvckNsaWNrZWQgPSBmYWxzZTsKICAg
ICAgICBsaXN0RWwuc2Nyb2xsVG9wID0gMDsKICAgICAgICBzeW5jSXRlbUhpZ2hsaWdodCgpOwog
ICAgICAgIGNvbnN0IGVsID0gbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5pdG1bZGF0YS1pZD0iJyAr
IHNlbGVjdGVkSWQgKyAnIl0nKTsKICAgICAgICBpZiAoZWwpIGVsLnNjcm9sbEludG9WaWV3KHsg
YmxvY2s6ICduZWFyZXN0JyB9KTsKICAgICAgICB1cGRhdGVMb2NhdGVCdG4oKTsKICAgIH0KICAg
IGZ1bmN0aW9uIGp1bXBUb0xhc3RQYXN0ZSgpIHsKICAgICAgICBpZiAoIWxhc3RQYXN0ZUlkKSBy
ZXR1cm47CiAgICAgICAgLy8gQWxyZWFkeSBsb2NhdGVkIG9uIGxhc3QgcGFzdGUg4oaSIGNhbmNl
bCBhbmQgc2VsZWN0IGZpcnN0CiAgICAgICAgaWYgKGxvY2F0ZUFjdGl2ZSAmJiArc2VsZWN0ZWRJ
ZCA9PT0gK2xhc3RQYXN0ZUlkKSB7CiAgICAgICAgICAgIHNlbGVjdEZpcnN0SXRlbSgpOwogICAg
ICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGxvY2F0ZUFjdGl2ZSA9IHRydWU7CiAg
ICAgICAgc2VsZWN0Rmlyc3RPblNob3cgPSBmYWxzZTsKICAgICAgICAvLyBDbGVhciBmaWx0ZXJz
IHNvIHRoZSBpdGVtIGlzIGZpbmRhYmxlIG9uIHRoZSB0YWIgd2hlcmUgaXQgd2FzIHVzZWQKICAg
ICAgICBxdWVyeSA9ICcnOwogICAgICAgIHRvZGF5T25seSA9IGZhbHNlOwogICAgICAgIHRyeSB7
CiAgICAgICAgICAgIGNvbnN0IHNyY2ggPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNo
Jyk7CiAgICAgICAgICAgIGNvbnN0IHNjbHIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2Vh
cmNoLWNscicpOwogICAgICAgICAgICBjb25zdCB3cmFwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ3NlYXJjaC13cmFwJyk7CiAgICAgICAgICAgIGNvbnN0IGJ0blRvZGF5ID0gZG9jdW1lbnQu
Z2V0RWxlbWVudEJ5SWQoJ2J0bi10b2RheScpOwogICAgICAgICAgICBpZiAoc3JjaCkgeyBzcmNo
LnZhbHVlID0gJyc7IHNyY2guY2xhc3NMaXN0LnJlbW92ZSgnaGFzLXZhbCcpOyB9CiAgICAgICAg
ICAgIGlmIChzY2xyKSBzY2xyLnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgICAgICAgICAgIGlm
ICh3cmFwKSB3cmFwLmNsYXNzTGlzdC5yZW1vdmUoJ29wZW4nKTsKICAgICAgICAgICAgaWYgKGJ0
blRvZGF5KSBidG5Ub2RheS5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgIH0gY2F0Y2gg
e30KICAgICAgICBjb25zdCB0YWIgPSBbJ2FsbCcsJ3RleHQnLCdpbWFnZScsJ2ZpbGUnLCdwaW5u
ZWQnXS5pbmNsdWRlcyhsYXN0UGFzdGVUYWIpCiAgICAgICAgICAgID8gbGFzdFBhc3RlVGFiIDog
J2FsbCc7CiAgICAgICAgY29uc3QgcHJldlRhYiA9IGN1clRhYjsKICAgICAgICBjdXJUYWIgPSB0
YWI7CiAgICAgICAgbG9hZGluZ01vcmUgPSBmYWxzZTsKICAgICAgICBtYXJrVGFiKHRhYik7CiAg
ICAgICAgY2xlYXJNdWx0aSgpOwogICAgICAgIHNlbGVjdGVkSWQgPSBsYXN0UGFzdGVJZDsKICAg
ICAgICB3aW5kb3cuX19wZW5kaW5nSnVtcElkID0gbGFzdFBhc3RlSWQ7CiAgICAgICAgd2luZG93
Ll9fanVtcExvYWRUcmllcyA9IDA7CiAgICAgICAgd2luZG93Ll9fanVtcEZlbGxCYWNrID0gZmFs
c2U7CiAgICAgICAgdXBkYXRlTG9jYXRlQnRuKCk7CiAgICAgICAgcmVxdWVzdFZpZXcoKTsKICAg
IH0KCiAgICBmdW5jdGlvbiByZXF1ZXN0VmlldygpIHsKICAgICAgICBhaGsoJ3NldFZpZXcnLCBj
dXJUYWIsIHF1ZXJ5LCB0b2RheU9ubHkgPyAnMScgOiAnMCcpOwogICAgfQogICAgZnVuY3Rpb24g
cmVxdWVzdE1vcmUoKSB7CiAgICAgICAgaWYgKGxvYWRpbmdNb3JlKSByZXR1cm47CiAgICAgICAg
aWYgKGRpc2tUb3RhbCA+IDAgJiYgYWxsQ2xpcHMubGVuZ3RoID49IGRpc2tUb3RhbCkgcmV0dXJu
OwogICAgICAgIGxvYWRpbmdNb3JlID0gdHJ1ZTsKICAgICAgICBhaGsoJ2xvYWRNb3JlJyk7CiAg
ICB9CiAgICBjb25zdCBFTVBUWV9NU0cgPSB7CiAgICAgICAgYWxsOiAgICAn5pqC5peg6K6w5b2V
77yM5aSN5Yi25ZCO6Ieq5Yqo5Ye6546wJywKICAgICAgICB0ZXh0OiAgICfmmoLml6DmlofmnKwn
LAogICAgICAgIGltYWdlOiAgJ+aaguaXoOWbvuWDjycsCiAgICAgICAgZmlsZTogICAn5pqC5peg
5paH5Lu2JywKICAgICAgICBwaW5uZWQ6ICfmmoLml6DmlLbol48nCiAgICB9OwoKICAgIGZ1bmN0
aW9uIGFoa0ludm9rZShtZXRob2QsIGFyZ3MpIHsKICAgICAgICB0cnkgewogICAgICAgICAgICBj
b25zdCBob3N0ID0gY2hyb21lLndlYnZpZXcuaG9zdE9iamVjdHMuc3luYy5haGs7CiAgICAgICAg
ICAgIGlmICghaG9zdCkgcmV0dXJuOwogICAgICAgICAgICBsZXQgY2FsbGVkID0gZmFsc2U7CiAg
ICAgICAgICAgIGlmICh0eXBlb2YgaG9zdC5jYWxsID09PSAnZnVuY3Rpb24nKSB7CiAgICAgICAg
ICAgICAgICB0cnkgeyBob3N0LmNhbGwobWV0aG9kLCAuLi5hcmdzKTsgY2FsbGVkID0gdHJ1ZTsg
fSBjYXRjaCB7fQogICAgICAgICAgICB9CiAgICAgICAgICAgIGlmICghY2FsbGVkICYmIHR5cGVv
ZiBob3N0W21ldGhvZF0gPT09ICdmdW5jdGlvbicpIHsKICAgICAgICAgICAgICAgIHRyeSB7IGhv
c3RbbWV0aG9kXSguLi5hcmdzKTsgY2FsbGVkID0gdHJ1ZTsgfSBjYXRjaCB7fQogICAgICAgICAg
ICAgICAgaWYgKCFjYWxsZWQpIHsKICAgICAgICAgICAgICAgICAgICB0cnkgeyBob3N0W21ldGhv
ZF0oLi4uYXJncyk7IGNhbGxlZCA9IHRydWU7IH0gY2F0Y2gge30KICAgICAgICAgICAgICAgIH0K
ICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAoIWNhbGxlZCAmJiBob3N0W21ldGhvZF0gIT0g
bnVsbCAmJiB0eXBlb2YgaG9zdFttZXRob2RdICE9PSAnZnVuY3Rpb24nKSB7CiAgICAgICAgICAg
ICAgICB0cnkgeyB2b2lkIGhvc3RbbWV0aG9kXTsgfSBjYXRjaCB7fQogICAgICAgICAgICB9CiAg
ICAgICAgfSBjYXRjaCAoZSkgeyBjb25zb2xlLndhcm4oJ2Foay4nICsgbWV0aG9kLCBlKTsgfQog
ICAgfQogICAgZnVuY3Rpb24gYWhrKG1ldGhvZCwgLi4uYXJncykgewogICAgICAgIGFoa0ludm9r
ZShtZXRob2QsIGFyZ3MpOwogICAgfQogICAgZnVuY3Rpb24gYWhrUmV0KG1ldGhvZCwgLi4uYXJn
cykgewogICAgICAgIHRyeSB7CiAgICAgICAgICAgIGNvbnN0IGhvc3QgPSBjaHJvbWUud2Vidmll
dy5ob3N0T2JqZWN0cy5zeW5jLmFoazsKICAgICAgICAgICAgaWYgKCFob3N0KSByZXR1cm4gbnVs
bDsKICAgICAgICAgICAgbGV0IHJldCA9IG51bGw7CiAgICAgICAgICAgIGlmICh0eXBlb2YgaG9z
dC5jYWxsID09PSAnZnVuY3Rpb24nKSB7CiAgICAgICAgICAgICAgICB0cnkgeyByZXQgPSBob3N0
LmNhbGwobWV0aG9kLCAuLi5hcmdzKTsgfSBjYXRjaCB7fQogICAgICAgICAgICB9CiAgICAgICAg
ICAgIGlmIChyZXQgPT0gbnVsbCAmJiB0eXBlb2YgaG9zdFttZXRob2RdID09PSAnZnVuY3Rpb24n
KSB7CiAgICAgICAgICAgICAgICB0cnkgeyByZXQgPSBob3N0W21ldGhvZF0oLi4uYXJncyk7IH0g
Y2F0Y2gge30KICAgICAgICAgICAgICAgIGlmIChyZXQgPT0gbnVsbCkgewogICAgICAgICAgICAg
ICAgICAgIHRyeSB7IHJldCA9IGhvc3RbbWV0aG9kXSguLi5hcmdzKTsgfSBjYXRjaCB7fQogICAg
ICAgICAgICAgICAgfQogICAgICAgICAgICB9CiAgICAgICAgICAgIGlmIChyZXQgPT0gbnVsbCAm
JiBob3N0W21ldGhvZF0gIT0gbnVsbCAmJiB0eXBlb2YgaG9zdFttZXRob2RdICE9PSAnZnVuY3Rp
b24nKQogICAgICAgICAgICAgICAgcmV0ID0gaG9zdFttZXRob2RdOwogICAgICAgICAgICBpZiAo
cmV0ID09IG51bGwpIHJldHVybiBudWxsOwogICAgICAgICAgICBpZiAodHlwZW9mIHJldCA9PT0g
J3N0cmluZycgfHwgdHlwZW9mIHJldCA9PT0gJ251bWJlcicgfHwgdHlwZW9mIHJldCA9PT0gJ2Jv
b2xlYW4nKQogICAgICAgICAgICAgICAgcmV0dXJuIHJldDsKICAgICAgICAgICAgdHJ5IHsgcmV0
dXJuIFN0cmluZyhyZXQpOyB9IGNhdGNoIHsgcmV0dXJuIHJldDsgfQogICAgICAgIH0gY2F0Y2gg
KGUpIHsgY29uc29sZS53YXJuKCdhaGtSZXQuJyArIG1ldGhvZCwgZSk7IH0KICAgICAgICByZXR1
cm4gbnVsbDsKICAgIH0KCiAgICAvLyBFYXJseSBBSEsgX19zZXRUaHVtYiBjYW4gYXJyaXZlIGJl
Zm9yZSBET00gbm9kZXMgZXhpc3Qg4oCUIGtlZXAgdW50aWwgYmluZAogICAgY29uc3QgdGh1bWJD
YWNoZSA9IG5ldyBNYXAoKTsKCiAgICAvKiogUHJlZmVyIGRhdGEtVVJMIChBSEspLCB0aGVuIHZp
cnR1YWwtaG9zdCBmaWxlIFVSTCAqLwogICAgZnVuY3Rpb24gYmluZFN0b3JlVGh1bWIoaW1nLCBm
aWxlLCBpZCwgZmFsbGJhY2spIHsKICAgICAgICBpbWcuZGF0YXNldC50aHVtYklkID0gU3RyaW5n
KGlkKTsKICAgICAgICBpbWcuYWx0ID0gJyc7CiAgICAgICAgY29uc3QgZmFpbFRpbWVyID0gc2V0
VGltZW91dCgoKSA9PiB7CiAgICAgICAgICAgIGlmICghaW1nLnNyYyB8fCBpbWcubmF0dXJhbFdp
ZHRoIDwgMSkKICAgICAgICAgICAgICAgIGltZy5hbHQgPSAn5peg5rOV5Yqg6L29JzsKICAgICAg
ICB9LCAxMDAwMCk7CiAgICAgICAgaW1nLl9mYWlsVGltZXIgPSBmYWlsVGltZXI7CiAgICAgICAg
Y29uc3QgcHJldkxvYWQgPSBpbWcub25sb2FkOwogICAgICAgIGltZy5vbmxvYWQgPSBlID0+IHsK
ICAgICAgICAgICAgY2xlYXJUaW1lb3V0KGZhaWxUaW1lcik7CiAgICAgICAgICAgIGltZy5hbHQg
PSAnJzsKICAgICAgICAgICAgaWYgKHR5cGVvZiBwcmV2TG9hZCA9PT0gJ2Z1bmN0aW9uJykgcHJl
dkxvYWQuY2FsbChpbWcsIGUpOwogICAgICAgIH07CiAgICAgICAgaW1nLm9uZXJyb3IgPSAoKSA9
PiB7CiAgICAgICAgICAgIGlmIChmaWxlICYmICFpbWcuZGF0YXNldC5yZXRyaWVkKSB7CiAgICAg
ICAgICAgICAgICBpbWcuZGF0YXNldC5yZXRyaWVkID0gJzEnOwogICAgICAgICAgICAgICAgaW1n
LnNyYyA9IFNUT1JFX0JBU0UgKyBTdHJpbmcoZmlsZSkuc3BsaXQoJy8nKS5wb3AoKTsKICAgICAg
ICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAgICAgICAgICBpbWcub25lcnJvciA9
IG51bGw7CiAgICAgICAgfTsKICAgICAgICBjb25zdCBjYWNoZWQgPSB0aHVtYkNhY2hlLmdldChT
dHJpbmcoaWQpKTsKICAgICAgICBjb25zdCBkYXRhVXJsID0gKGZhbGxiYWNrICYmIFN0cmluZyhm
YWxsYmFjaykuc3RhcnRzV2l0aCgnZGF0YTonKSkKICAgICAgICAgICAgPyBTdHJpbmcoZmFsbGJh
Y2spCiAgICAgICAgICAgIDogKGNhY2hlZCAmJiBTdHJpbmcoY2FjaGVkKS5zdGFydHNXaXRoKCdk
YXRhOicpID8gU3RyaW5nKGNhY2hlZCkgOiAnJyk7CiAgICAgICAgaWYgKGRhdGFVcmwpIHsKICAg
ICAgICAgICAgaW1nLnNyYyA9IGRhdGFVcmw7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9
CiAgICAgICAgaWYgKGZpbGUpIHsKICAgICAgICAgICAgY29uc3QgYmFyZSA9IFN0cmluZyhmaWxl
KS5zcGxpdCgnLycpLnBvcCgpOwogICAgICAgICAgICBpbWcuc3JjID0gU1RPUkVfQkFTRSArIGJh
cmU7CiAgICAgICAgfQogICAgfQoKICAgIHdpbmRvdy5fX3NldFRodW1iID0gKGlkLCB1cmwpID0+
IHsKICAgICAgICBpZiAoIXVybCkgcmV0dXJuOwogICAgICAgIGNvbnN0IGtleSA9IFN0cmluZyhp
ZCk7CiAgICAgICAgdGh1bWJDYWNoZS5zZXQoa2V5LCB1cmwpOwogICAgICAgIGxldCBoaXQgPSAw
OwogICAgICAgIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5pdG1bZGF0YS1pZD0iJyArIGtl
eSArICciXSBpbWcuaS10aHVtYicpLmZvckVhY2goaW1nID0+IHsKICAgICAgICAgICAgaWYgKGlt
Zy5fZmFpbFRpbWVyKSB0cnkgeyBjbGVhclRpbWVvdXQoaW1nLl9mYWlsVGltZXIpOyB9IGNhdGNo
IHt9CiAgICAgICAgICAgIGltZy5vbmVycm9yID0gbnVsbDsKICAgICAgICAgICAgaW1nLmFsdCA9
ICcnOwogICAgICAgICAgICBpbWcuc3JjID0gdXJsOwogICAgICAgICAgICBoaXQrKzsKICAgICAg
ICB9KTsKICAgICAgICAvLyBBbHNvIG1hdGNoIG51bWVyaWMgaWQgYXR0cmlidXRlIHF1aXJrcwog
ICAgICAgIGlmICghaGl0KSB7CiAgICAgICAgICAgIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwo
J2ltZy5pLXRodW1iW2RhdGEtdGh1bWItaWQ9IicgKyBrZXkgKyAnIl0nKS5mb3JFYWNoKGltZyA9
PiB7CiAgICAgICAgICAgICAgICBpZiAoaW1nLl9mYWlsVGltZXIpIHRyeSB7IGNsZWFyVGltZW91
dChpbWcuX2ZhaWxUaW1lcik7IH0gY2F0Y2gge30KICAgICAgICAgICAgICAgIGltZy5vbmVycm9y
ID0gbnVsbDsKICAgICAgICAgICAgICAgIGltZy5hbHQgPSAnJzsKICAgICAgICAgICAgICAgIGlt
Zy5zcmMgPSB1cmw7CiAgICAgICAgICAgIH0pOwogICAgICAgIH0KICAgIH07CgogICAgZnVuY3Rp
b24gaXNEcmFnRXhjbHVkZSh0KSB7CiAgICAgICAgcmV0dXJuICEhdC5jbG9zZXN0KCcjc2VhcmNo
LXdyYXAsICNidG4tc2VhcmNoLCAjYnRuLWxvY2F0ZSwgI2J0bi10b2RheSwgI2J0bi1waW4sICNi
dG4tY2xyLCAjbXVsdGktY250LCAudGFiLCAuaXRtLCAjdGFiLWFjdGlvbnMsICNjdHgsICNjbHIt
ZGxnLCAjcGF0aC10aXAsIGJ1dHRvbiwgaW5wdXQsIGEnKTsKICAgIH0KICAgIGRvY3VtZW50Lmdl
dEVsZW1lbnRCeUlkKCdhcHAnKS5hZGRFdmVudExpc3RlbmVyKCdtb3VzZWRvd24nLCBlID0+IHsK
ICAgICAgICBpZiAoZS5idXR0b24gIT09IDApIHJldHVybjsKICAgICAgICBpZiAoaXNEcmFnRXhj
bHVkZShlLnRhcmdldCkpIHJldHVybjsKICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAg
ICAgYWhrKCdzdGFydERyYWcnKTsKICAgIH0sIHRydWUpOwoKICAgIGNvbnN0IGlzVXJsICA9IHMg
PT4gL15odHRwcz86XC9cLy9pLnRlc3QoKHMgfHwgJycpLnRyaW0oKSk7CgogICAgZnVuY3Rpb24g
YWdvKGRhdGVTdHIpIHsKICAgICAgICB0cnkgewogICAgICAgICAgICBjb25zdCBkID0gbmV3IERh
dGUoU3RyaW5nKGRhdGVTdHIpLnJlcGxhY2UoJyAnLCAnVCcpKTsKICAgICAgICAgICAgY29uc3Qg
cyA9IChEYXRlLm5vdygpIC0gZCkgLyAxMDAwIHwgMDsKICAgICAgICAgICAgaWYgKHMgPCA2MCkg
cmV0dXJuICfliJrliJonOwogICAgICAgICAgICBpZiAocyA8IDM2MDApIHJldHVybiAocyAvIDYw
IHwgMCkgKyAnIOWIhumSn+WJjSc7CiAgICAgICAgICAgIGlmIChzIDwgODY0MDApIHJldHVybiAo
cyAvIDM2MDAgfCAwKSArICcg5bCP5pe25YmNJzsKICAgICAgICAgICAgcmV0dXJuIChzIC8gODY0
MDAgfCAwKSArICcg5aSp5YmNJzsKICAgICAgICB9IGNhdGNoIHsgcmV0dXJuIGRhdGVTdHI7IH0K
ICAgIH0KCiAgICBmdW5jdGlvbiBub3JtVHlwZSh0KSB7CiAgICAgICAgdCA9IFN0cmluZyh0IHx8
ICcnKS50b0xvd2VyQ2FzZSgpOwogICAgICAgIGlmICh0ID09PSAnaW1hZ2UnIHx8IHQgPT09ICdp
bWcnIHx8IHQgPT09ICdiaXRtYXAnKSByZXR1cm4gJ2ltYWdlJzsKICAgICAgICBpZiAodCA9PT0g
J2ZpbGUnICB8fCB0ID09PSAnZmlsZXMnKSByZXR1cm4gJ2ZpbGUnOwogICAgICAgIHJldHVybiAn
dGV4dCc7CiAgICB9CiAgICBmdW5jdGlvbiBpc1Bpbm5lZChjKSB7CiAgICAgICAgcmV0dXJuIGMu
cGlubmVkID09PSB0cnVlIHx8IGMucGlubmVkID09PSAxIHx8IGMucGlubmVkID09PSAndHJ1ZScg
fHwgYy5waW5uZWQgPT09ICcxJzsKICAgIH0KICAgIGZ1bmN0aW9uIGlzUGFzdGVkKGMpIHsKICAg
ICAgICByZXR1cm4gYy5wYXN0ZWQgPT09IHRydWUgfHwgYy5wYXN0ZWQgPT09IDEgfHwgYy5wYXN0
ZWQgPT09ICd0cnVlJyB8fCBjLnBhc3RlZCA9PT0gJzEnOwogICAgfQoKICAgIGZ1bmN0aW9uIGlz
TWFya2Rvd24odGV4dCkgewogICAgICAgIGlmICghdGV4dCB8fCB0ZXh0Lmxlbmd0aCA8IDQpIHJl
dHVybiBmYWxzZTsKICAgICAgICByZXR1cm4gLyg/Ol58XG4pI3sxLDZ9IHxeWy0qK10gfFwqXCpb
Xipcbl0rXCpcKnxfX1teX1xuXStfX3woPzpefFxuKT4gfF5gYGB8YFteYF0rYHxcWy4rXF1cKC4r
XCl8XHwuK1x8LitcfC8udGVzdCh0ZXh0KTsKICAgIH0KICAgIGZ1bmN0aW9uIGVzY0F0dHIocykg
ewogICAgICAgIHJldHVybiBTdHJpbmcocyB8fCAnJykKICAgICAgICAgICAgLnJlcGxhY2UoLyYv
ZywgJyZhbXA7JykKICAgICAgICAgICAgLnJlcGxhY2UoLyIvZywgJyZxdW90OycpCiAgICAgICAg
ICAgIC5yZXBsYWNlKC88L2csICcmbHQ7JykKICAgICAgICAgICAgLnJlcGxhY2UoLz4vZywgJyZn
dDsnKTsKICAgIH0KCiAgICBmdW5jdGlvbiB0b2RheVByZWZpeCgpIHsKICAgICAgICBjb25zdCBk
ID0gbmV3IERhdGUoKTsKICAgICAgICBjb25zdCBwID0gbiA9PiBTdHJpbmcobikucGFkU3RhcnQo
MiwgJzAnKTsKICAgICAgICByZXR1cm4gZC5nZXRGdWxsWWVhcigpICsgJy0nICsgcChkLmdldE1v
bnRoKCkgKyAxKSArICctJyArIHAoZC5nZXREYXRlKCkpOwogICAgfQogICAgZnVuY3Rpb24gaXNU
b2RheUNsaXAoYykgewogICAgICAgIHJldHVybiBTdHJpbmcoYy50aW1lIHx8ICcnKS5zdGFydHNX
aXRoKHRvZGF5UHJlZml4KCkpOwogICAgfQoKICAgIGZ1bmN0aW9uIGZpbHRlcihjbGlwcywgdGFi
LCBxKSB7CiAgICAgICAgLy8gQUhLIGFscmVhZHkgZmlsdGVycyBieSB0YWIgLyBxdWVyeSAvIHRv
ZGF5IOKAlCBkbyBub3QgY2xvbmUgZXZlcnkgcm93CiAgICAgICAgcmV0dXJuIGNsaXBzOwogICAg
fQoKICAgIGZ1bmN0aW9uIG1hcmtQYXN0ZWRMb2NhbChpZHMpIHsKICAgICAgICBjb25zdCBsaXN0
ID0gQXJyYXkuaXNBcnJheShpZHMpID8gaWRzIDogW2lkc107CiAgICAgICAgaWYgKGxpc3QubGVu
Z3RoKQogICAgICAgICAgICByZW1lbWJlckxhc3RQYXN0ZShsaXN0W2xpc3QubGVuZ3RoIC0gMV0p
OwogICAgICAgIGNvbnN0IGJhZGdlSHRtbCA9IGA8c3ZnIHZpZXdCb3g9IjAgMCAxNiAxNiIgZmls
bD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMi40IiBzdHJva2Ut
bGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9pbj0icm91bmQiPjxwb2x5bGluZSBwb2ludHM9
IjMuNSA4LjUgNi41IDExLjUgMTIuNSA0LjUiLz48L3N2Zz5gOwogICAgICAgIGxpc3QuZm9yRWFj
aChpZCA9PiB7CiAgICAgICAgICAgIGNvbnN0IGMgPSBhbGxDbGlwcy5maW5kKHggPT4gK3guaWQg
PT09ICtpZCk7CiAgICAgICAgICAgIGlmIChjKSBjLnBhc3RlZCA9IHRydWU7CiAgICAgICAgICAg
IGNvbnN0IGljbyA9IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcuaXRtW2RhdGEtaWQ9IicgKyBpZCAr
ICciXSAuaS1pY28nKTsKICAgICAgICAgICAgaWYgKGljbyAmJiAhaWNvLnF1ZXJ5U2VsZWN0b3Io
Jy5pLXVzZWQnKSkgewogICAgICAgICAgICAgICAgY29uc3QgYmFkZ2UgPSBkb2N1bWVudC5jcmVh
dGVFbGVtZW50KCdzcGFuJyk7CiAgICAgICAgICAgICAgICBiYWRnZS5jbGFzc05hbWUgPSAnaS11
c2VkJzsKICAgICAgICAgICAgICAgIGJhZGdlLnRpdGxlID0gJ+W3sueymOi0tCc7CiAgICAgICAg
ICAgICAgICBiYWRnZS5pbm5lckhUTUwgPSBiYWRnZUh0bWw7CiAgICAgICAgICAgICAgICBpY28u
YXBwZW5kQ2hpbGQoYmFkZ2UpOwogICAgICAgICAgICB9CiAgICAgICAgfSk7CiAgICB9CgogICAg
Y29uc3QgbGlzdEVsICA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdsaXN0Jyk7CiAgICBjb25z
dCBlbXB0eUVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2VtcHR5Jyk7CiAgICBjb25zdCBz
a2VsRWwgID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NrZWwnKTsKICAgIGNvbnN0IGJ0blRv
cCAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLXRvcCcpOwogICAgZnVuY3Rpb24gc2V0
Qm9vdExvYWRpbmcob24pIHsKICAgICAgICBib290TG9hZGluZyA9ICEhb247CiAgICAgICAgaWYg
KGJvb3RMb2FkaW5nKSB3aW5kb3cuX19za2VsU2luY2UgPSBEYXRlLm5vdygpOwogICAgICAgIGlm
IChza2VsRWwpIHNrZWxFbC5jbGFzc0xpc3QudG9nZ2xlKCdvbicsIGJvb3RMb2FkaW5nKTsKICAg
ICAgICBpZiAoYm9vdExvYWRpbmcgJiYgZW1wdHlFbCkgZW1wdHlFbC5jbGFzc0xpc3QucmVtb3Zl
KCdvbicpOwogICAgICAgIGNvbnN0IGFwcCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdhcHAn
KTsKICAgICAgICBpZiAoYXBwKSBhcHAuY2xhc3NMaXN0LnRvZ2dsZSgnYm9vdC1sb2FkaW5nJywg
Ym9vdExvYWRpbmcpOwogICAgfQogICAgd2luZG93LnNldEJvb3RMb2FkaW5nID0gc2V0Qm9vdExv
YWRpbmc7CiAgICB3aW5kb3cuZm9yY2VFbmRCb290TG9hZGluZyA9IGZ1bmN0aW9uKCkgewogICAg
ICAgIHNldEJvb3RMb2FkaW5nKGZhbHNlKTsKICAgICAgICB0cnkgeyByZW5kZXIoKTsgfSBjYXRj
aCAoZSkge30KICAgIH07CiAgICAvLyBTYWZldHk6IG5ldmVyIGxlYXZlIHNrZWxldG9uIHN0dWNr
IGlmIGhvc3QgcHVzaCBpcyBkcm9wcGVkIHdoaWxlIHN0aWxsIGxvYWRpbmcKICAgIHNldFRpbWVv
dXQoKCkgPT4gewogICAgICAgIGlmICh3aW5kb3cuX19kYXRhUmVhZHkgfHwgIWJvb3RMb2FkaW5n
KSByZXR1cm47CiAgICAgICAgc2V0Qm9vdExvYWRpbmcoZmFsc2UpOwogICAgICAgIHRyeSB7IHJl
bmRlcigpOyB9IGNhdGNoIHt9CiAgICB9LCA4MDAwKTsKCiAgICBmdW5jdGlvbiB1cGRhdGVUb3BC
dG4oKSB7CiAgICAgICAgaWYgKCFidG5Ub3AgfHwgIWxpc3RFbCkgcmV0dXJuOwogICAgICAgIGJ0
blRvcC5jbGFzc0xpc3QudG9nZ2xlKCdvbicsIGxpc3RFbC5zY3JvbGxUb3AgPiA0OCk7CiAgICB9
CiAgICBmdW5jdGlvbiBvbkxpc3RTY3JvbGwoKSB7CiAgICAgICAgaGlkZVBhdGhUaXAoKTsKICAg
ICAgICB1cGRhdGVUb3BCdG4oKTsKICAgICAgICBpZiAobG9hZGluZ01vcmUpIHJldHVybjsKICAg
ICAgICAvLyDot53nprvlupXpg6ggMjQwcHgg6Kem5Y+R5Yqg6L295pu05aSa77yM5q+U5Y6f5p2l
IDEwMHB4IOabtOeos++8m+W/q+mAn+a7muWKqOaXtuS4jeS8mgogICAgICAgIC8vIOi/nue7rein
puWPkSByZXF1ZXN0TW9yZe+8iOW3sueUqCBsb2FkaW5nTW9yZSDpmLLph43lhaXvvIzkvYbmraTl
pITku43pgb/lhY3mipbliqjvvInjgIIKICAgICAgICBpZiAobGlzdEVsLnNjcm9sbFRvcCArIGxp
c3RFbC5jbGllbnRIZWlnaHQgPj0gbGlzdEVsLnNjcm9sbEhlaWdodCAtIDI0MCkKICAgICAgICAg
ICAgcmVxdWVzdE1vcmUoKTsKICAgIH0KICAgIGxpc3RFbC5hZGRFdmVudExpc3RlbmVyKCdzY3Jv
bGwnLCBvbkxpc3RTY3JvbGwsIHsgcGFzc2l2ZTogdHJ1ZSB9KTsKICAgIGJ0blRvcC5hZGRFdmVu
dExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAg
ICAgICAgbGlzdEVsLnNjcm9sbFRvKHsgdG9wOiAwLCBiZWhhdmlvcjogJ3Ntb290aCcgfSk7CiAg
ICB9KTsKCiAgICBmdW5jdGlvbiB2aXNpYmxlTGlzdCgpIHsgcmV0dXJuIGZpbHRlcihhbGxDbGlw
cywgY3VyVGFiLCBxdWVyeSk7IH0KICAgIGZ1bmN0aW9uIGVzY0h0bWwocykgewogICAgICAgIHJl
dHVybiBTdHJpbmcocyA/PyAnJykucmVwbGFjZSgvJi9nLCcmYW1wOycpLnJlcGxhY2UoLzwvZywn
Jmx0OycpLnJlcGxhY2UoLz4vZywnJmd0OycpLnJlcGxhY2UoLyIvZywnJnF1b3Q7Jyk7CiAgICB9
CiAgICBmdW5jdGlvbiBxdWVyeVRlcm1zKHEpIHsKICAgICAgICByZXR1cm4gU3RyaW5nKHEgfHwg
JycpLnNwbGl0KCd8JykubWFwKHQgPT4gdC50cmltKCkpLmZpbHRlcihCb29sZWFuKTsKICAgIH0K
ICAgIGZ1bmN0aW9uIGhsSHRtbCh0ZXh0KSB7CiAgICAgICAgY29uc3QgdGVybXMgPSBxdWVyeVRl
cm1zKHF1ZXJ5KTsKICAgICAgICBjb25zdCBzID0gU3RyaW5nKHRleHQgPz8gJycpOwogICAgICAg
IGlmICghdGVybXMubGVuZ3RoKSByZXR1cm4gZXNjSHRtbChzKTsKICAgICAgICBjb25zdCBsb3dl
ciA9IHMudG9Mb3dlckNhc2UoKTsKICAgICAgICBjb25zdCB0ZXJtTCA9IHRlcm1zLm1hcCh0ID0+
IHQudG9Mb3dlckNhc2UoKSk7CiAgICAgICAgbGV0IG91dCA9ICcnLCBpID0gMDsKICAgICAgICB3
aGlsZSAoaSA8IHMubGVuZ3RoKSB7CiAgICAgICAgICAgIGxldCBiZXN0SiA9IC0xLCBiZXN0TGVu
ID0gMDsKICAgICAgICAgICAgZm9yIChsZXQgdGkgPSAwOyB0aSA8IHRlcm1MLmxlbmd0aDsgdGkr
KykgewogICAgICAgICAgICAgICAgY29uc3QgdCA9IHRlcm1MW3RpXTsKICAgICAgICAgICAgICAg
IGlmICghdCkgY29udGludWU7CiAgICAgICAgICAgICAgICBjb25zdCBqID0gbG93ZXIuaW5kZXhP
Zih0LCBpKTsKICAgICAgICAgICAgICAgIGlmIChqIDwgMCkgY29udGludWU7CiAgICAgICAgICAg
ICAgICBpZiAoYmVzdEogPCAwIHx8IGogPCBiZXN0SiB8fCAoaiA9PT0gYmVzdEogJiYgdC5sZW5n
dGggPiBiZXN0TGVuKSkgewogICAgICAgICAgICAgICAgICAgIGJlc3RKID0gajsgYmVzdExlbiA9
IHQubGVuZ3RoOwogICAgICAgICAgICAgICAgfQogICAgICAgICAgICB9CiAgICAgICAgICAgIGlm
IChiZXN0SiA8IDApIHsgb3V0ICs9IGVzY0h0bWwocy5zbGljZShpKSk7IGJyZWFrOyB9CiAgICAg
ICAgICAgIG91dCArPSBlc2NIdG1sKHMuc2xpY2UoaSwgYmVzdEopKTsKICAgICAgICAgICAgb3V0
ICs9ICc8bWFyayBjbGFzcz0icS1obCI+JyArIGVzY0h0bWwocy5zbGljZShiZXN0SiwgYmVzdEog
KyBiZXN0TGVuKSkgKyAnPC9tYXJrPic7CiAgICAgICAgICAgIGkgPSBiZXN0SiArIE1hdGgubWF4
KDEsIGJlc3RMZW4pOwogICAgICAgIH0KICAgICAgICByZXR1cm4gb3V0OwogICAgfQogICAgZnVu
Y3Rpb24gc2V0SGxUZXh0KGVsLCB0ZXh0KSB7CiAgICAgICAgaWYgKCFlbCkgcmV0dXJuOwogICAg
ICAgIGNvbnN0IHEgPSBTdHJpbmcocXVlcnkgfHwgJycpLnRyaW0oKTsKICAgICAgICBpZiAoIXEp
IHsKICAgICAgICAgICAgZWwuY2xhc3NMaXN0LnJlbW92ZSgnaGFzLWhsJyk7CiAgICAgICAgICAg
IGVsLnRleHRDb250ZW50ID0gdGV4dCA9PSBudWxsID8gJycgOiBTdHJpbmcodGV4dCk7CiAgICAg
ICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgZWwuY2xhc3NMaXN0LmFkZCgnaGFzLWhs
Jyk7CiAgICAgICAgZWwuaW5uZXJIVE1MID0gaGxIdG1sKHRleHQpOwogICAgfQoKCiAgICBmdW5j
dGlvbiBhcHBseVRhYlN3aXRjaEFuaW0oKSB7CiAgICAgICAgaWYgKCF0YWJTd2l0Y2hBbmltRGly
KSByZXR1cm47CiAgICAgICAgY29uc3QgZGlyID0gdGFiU3dpdGNoQW5pbURpcjsKICAgICAgICB0
YWJTd2l0Y2hBbmltRGlyID0gMDsKICAgICAgICBjb25zdCBhbmltID0gZGlyID4gMCA/ICd0YWJQ
YW5lSW5McicgOiAndGFiUGFuZUluUmwnOwogICAgICAgIGNvbnN0IHRhcmdldHMgPSBbXTsKICAg
ICAgICBsaXN0RWwucXVlcnlTZWxlY3RvckFsbCgnLml0bSwgI2xpc3QtbW9yZScpLmZvckVhY2go
ZWwgPT4gdGFyZ2V0cy5wdXNoKGVsKSk7CiAgICAgICAgaWYgKGVtcHR5RWwuY2xhc3NMaXN0LmNv
bnRhaW5zKCdvbicpKSB0YXJnZXRzLnB1c2goZW1wdHlFbCk7CiAgICAgICAgaWYgKCF0YXJnZXRz
Lmxlbmd0aCkgcmV0dXJuOwogICAgICAgIHRhcmdldHMuZm9yRWFjaCgoZWwsIGkpID0+IHsKICAg
ICAgICAgICAgZWwuc3R5bGUuYW5pbWF0aW9uID0gYW5pbSArICcgMC4zNHMgY3ViaWMtYmV6aWVy
KDAuMjIsIDEsIDAuMzYsIDEpICcKICAgICAgICAgICAgICAgICsgTWF0aC5taW4oaSAqIDI0LCAx
NjgpICsgJ21zIGJvdGgnOwogICAgICAgIH0pOwogICAgICAgIHNldFRpbWVvdXQoKCkgPT4geyB0
YXJnZXRzLmZvckVhY2goZWwgPT4geyBlbC5zdHlsZS5hbmltYXRpb24gPSAnJzsgfSk7IH0sIDU2
MCk7CiAgICB9CgogICAgZnVuY3Rpb24gdGFiSW5kZXgodGFiKSB7CiAgICAgICAgY29uc3QgaSA9
IFRBQl9PUkRFUi5pbmRleE9mKHRhYik7CiAgICAgICAgcmV0dXJuIGkgPj0gMCA/IGkgOiAwOwog
ICAgfQoKICAgIGZ1bmN0aW9uIG1vdmVUYWJJbmsoaW5zdGFudCwgdGFyZ2V0RWwpIHsKICAgICAg
ICBjb25zdCBpbmsgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGFiLWluaycpOwogICAgICAg
IGNvbnN0IHRhYnMgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGFicycpOwogICAgICAgIGNv
bnN0IGVsID0gdGFyZ2V0RWwgfHwgZG9jdW1lbnQucXVlcnlTZWxlY3RvcignI3RhYnMgLnRhYi5v
bicpOwogICAgICAgIGlmICghaW5rIHx8ICF0YWJzIHx8ICFlbCkgcmV0dXJuOwogICAgICAgIGNv
bnN0IHRyID0gdGFicy5nZXRCb3VuZGluZ0NsaWVudFJlY3QoKTsKICAgICAgICBjb25zdCByID0g
ZWwuZ2V0Qm91bmRpbmdDbGllbnRSZWN0KCk7CiAgICAgICAgY29uc3QgeCA9IHIubGVmdCAtIHRy
LmxlZnQ7CiAgICAgICAgY29uc3QgaCA9IE1hdGgubWF4KDIwLCBNYXRoLnJvdW5kKHIuaGVpZ2h0
KSk7CiAgICAgICAgY29uc3QgeSA9IHIudG9wIC0gdHIudG9wOwogICAgICAgIGNvbnN0IHcgPSBN
YXRoLm1heCgyNCwgci53aWR0aCk7CiAgICAgICAgY29uc3QgcG9zID0gJ3RyYW5zbGF0ZTNkKCcg
KyB4ICsgJ3B4LCcgKyB5ICsgJ3B4LDApJzsKICAgICAgICBpbmsuc3R5bGUudHJhbnNmb3JtT3Jp
Z2luID0gJ2NlbnRlciBib3R0b20nOwogICAgICAgIGluay5zdHlsZS53aWR0aCA9IHcgKyAncHgn
OwogICAgICAgIGluay5zdHlsZS5oZWlnaHQgPSBoICsgJ3B4JzsKICAgICAgICBpZiAoaW5zdGFu
dCkgewogICAgICAgICAgICBpbmsuc3R5bGUudHJhbnNpdGlvbiA9ICdub25lJzsKICAgICAgICAg
ICAgaW5rLmNsYXNzTGlzdC5yZW1vdmUoJ3NxdWFzaCcpOwogICAgICAgICAgICBpbmsuc3R5bGUu
dHJhbnNmb3JtID0gcG9zICsgJyBzY2FsZVgoMSknOwogICAgICAgICAgICBpbmsub2Zmc2V0SGVp
Z2h0OwogICAgICAgICAgICBpbmsuc3R5bGUudHJhbnNpdGlvbiA9ICcnOwogICAgICAgICAgICBy
ZXR1cm47CiAgICAgICAgfQogICAgICAgIC8vIFNuYXAgdG8gaG92ZXJlZCB0YWIsIGV4cGFuZCBm
cm9tIGJvdHRvbS1jZW50ZXIg4oCUIG5vIHNsaWRpbmcgYmV0d2VlbiB0YWJzCiAgICAgICAgaW5r
LnN0eWxlLnRyYW5zaXRpb24gPSAnbm9uZSc7CiAgICAgICAgaW5rLnN0eWxlLnRyYW5zZm9ybSA9
IHBvcyArICcgc2NhbGVYKDAuMDAxKSc7CiAgICAgICAgaW5rLm9mZnNldEhlaWdodDsKICAgICAg
ICBpbmsuc3R5bGUudHJhbnNpdGlvbiA9ICcnOwogICAgICAgIGluay5jbGFzc0xpc3QuYWRkKCdz
cXVhc2gnKTsKICAgICAgICBpbmsuc3R5bGUudHJhbnNmb3JtID0gcG9zICsgJyBzY2FsZVgoMSkn
OwogICAgICAgIGNsZWFyVGltZW91dChpbmsuX3NxdWFzaFRpbWVyKTsKICAgICAgICBpbmsuX3Nx
dWFzaFRpbWVyID0gc2V0VGltZW91dCgoKSA9PiBpbmsuY2xhc3NMaXN0LnJlbW92ZSgnc3F1YXNo
JyksIDM0MCk7CiAgICB9CiAgICBmdW5jdGlvbiBtYXJrVGFiKHRhYiwgaW5zdGFudCkgewogICAg
ICAgIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJyN0YWJzIC50YWInKS5mb3JFYWNoKGVsID0+
CiAgICAgICAgICAgIGVsLmNsYXNzTGlzdC50b2dnbGUoJ29uJywgZWwuZGF0YXNldC50YWIgPT09
IHRhYikpOwogICAgICAgIG1vdmVUYWJJbmsoISFpbnN0YW50KTsKICAgIH0KICAgIGZ1bmN0aW9u
IGJpbmRUYWJJbmtIb3ZlcigpIHsKICAgICAgICBjb25zdCB0YWJzID0gZG9jdW1lbnQuZ2V0RWxl
bWVudEJ5SWQoJ3RhYnMnKTsKICAgICAgICBpZiAoIXRhYnMgfHwgdGFicy5faW5rSG92ZXJCb3Vu
ZCkgcmV0dXJuOwogICAgICAgIHRhYnMuX2lua0hvdmVyQm91bmQgPSB0cnVlOwogICAgICAgIHRh
YnMuYWRkRXZlbnRMaXN0ZW5lcigncG9pbnRlcm92ZXInLCBlID0+IHsKICAgICAgICAgICAgY29u
c3QgdGFiID0gZS50YXJnZXQuY2xvc2VzdCgnLnRhYicpOwogICAgICAgICAgICBpZiAoIXRhYiB8
fCAhdGFicy5jb250YWlucyh0YWIpKSByZXR1cm47CiAgICAgICAgICAgIG1vdmVUYWJJbmsoZmFs
c2UsIHRhYik7CiAgICAgICAgfSk7CiAgICAgICAgdGFicy5hZGRFdmVudExpc3RlbmVyKCdwb2lu
dGVybGVhdmUnLCBlID0+IHsKICAgICAgICAgICAgaWYgKGUucmVsYXRlZFRhcmdldCAmJiB0YWJz
LmNvbnRhaW5zKGUucmVsYXRlZFRhcmdldCkpIHJldHVybjsKICAgICAgICAgICAgbW92ZVRhYklu
ayhmYWxzZSk7CiAgICAgICAgfSk7CiAgICB9CmZ1bmN0aW9uIHNldFRhYih0YWIpIHsKICAgICAg
ICBpZiAodGFiID09PSBjdXJUYWIpIHJldHVybjsKICAgICAgICBjb25zdCBmcm9tID0gdGFiSW5k
ZXgoY3VyVGFiKTsKICAgICAgICBjb25zdCB0byA9IHRhYkluZGV4KHRhYik7CiAgICAgICAgdGFi
U3dpdGNoQW5pbURpciA9IHRvID4gZnJvbSA/IDEgOiAodG8gPCBmcm9tID8gLTEgOiAwKTsKICAg
ICAgICBjdXJUYWIgPSB0YWI7CiAgICAgICAgbG9hZGluZ01vcmUgPSBmYWxzZTsKICAgICAgICBt
YXJrVGFiKHRhYik7CgogICAgICAgIC8vIEtlZXAgc2VhcmNoICJ0b2RheSIgZmlsdGVyIGluIHN5
bmMgd2hlbiBzZWFyY2ggaXMgb3BlbgogICAgICAgIHRyeSB7CiAgICAgICAgICAgIGNvbnN0IHdy
YXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLXdyYXAnKTsKICAgICAgICAgICAg
Y29uc3QgYnRuVG9kYXkgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLXRvZGF5Jyk7CiAg
ICAgICAgICAgIGlmICh3cmFwICYmIHdyYXAuY2xhc3NMaXN0LmNvbnRhaW5zKCdvcGVuJykpIHsK
ICAgICAgICAgICAgICAgIGNvbnN0IHdhbnRUb2RheSA9IGZhbHNlOwogICAgICAgICAgICAgICAg
aWYgKHRvZGF5T25seSAhPT0gd2FudFRvZGF5KSB7CiAgICAgICAgICAgICAgICAgICAgdG9kYXlP
bmx5ID0gd2FudFRvZGF5OwogICAgICAgICAgICAgICAgICAgIGlmIChidG5Ub2RheSkgYnRuVG9k
YXkuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCB0b2RheU9ubHkpOwogICAgICAgICAgICAgICAgfQog
ICAgICAgICAgICB9CiAgICAgICAgfSBjYXRjaCB7fQoKICAgICAgICAvLyBEcm9wIHN0YWxlIChw
b3NzaWJseSBsb2FkLW1vcmUnZCkgbGlzdCBCRUZPUkUgcmVuZGVyIOKAlCBmaWx0ZXJpbmcgaHVu
ZHJlZHMKICAgICAgICAvLyBvZiBvbGQgcm93cyArIHN5bmMgaG9zdCBjYWxscyBvbiB0YWIgc3dp
dGNoIGZyZWV6ZXMgdGhlIFdlYlZpZXcuCiAgICAgICAgYWxsQ2xpcHMgPSBbXTsKICAgICAgICBk
aXNrVG90YWwgPSAwOwogICAgICAgIHNlbGVjdGVkSWQgPSBudWxsOwogICAgICAgIG11bHRpSWRz
ID0gW107CiAgICAgICAgbGlzdEVsLnNjcm9sbFRvcCA9IDA7CiAgICAgICAgLy8g5bu26L+f6aqo
5p625bGP562W55Wl77yadGFiIOWIh+aNoueerOmXtOS4jemXqiBza2VsZXRvbu+8iOWkmuaVsOaD
heWGteS4i+aVsOaNriA8MTgwbXMg5bCx5Yiw77yMCiAgICAgICAgLy8g6Zeq5LiA5LiL5Y+N6ICM
5piv5Zmq6Z+z77yJ44CC5Y+q5ZyoIDE4MG1zIOWGheayoeaUtuWIsCBfX3VwZGF0ZUNsaXBzIOaJ
jeihpSBzaGltbWVy44CCCiAgICAgICAgaWYgKHdpbmRvdy5fX3BlbmRpbmdTa2VsVGltZXIpIGNs
ZWFyVGltZW91dCh3aW5kb3cuX19wZW5kaW5nU2tlbFRpbWVyKTsKICAgICAgICB3aW5kb3cuX19w
ZW5kaW5nU2tlbFNpbmNlID0gRGF0ZS5ub3coKTsKICAgICAgICB3aW5kb3cuX19wZW5kaW5nU2tl
bFRpbWVyID0gc2V0VGltZW91dCgoKSA9PiB7CiAgICAgICAgICAgIHdpbmRvdy5fX3BlbmRpbmdT
a2VsVGltZXIgPSAwOwogICAgICAgICAgICAvLyDmlbDmja7liLDkuoblsLHot7Pov4cgc2tlbGV0
b27vvIhfX3VwZGF0ZUNsaXBzIOW3suaKiuWug+WFs+aOieS6hu+8iQogICAgICAgICAgICBpZiAo
IWJvb3RMb2FkaW5nKSBzZXRCb290TG9hZGluZyh0cnVlKTsKICAgICAgICB9LCAxODApOwogICAg
ICAgIHJlcXVlc3RWaWV3KCk7CiAgICByZW5kZXIoKTsKICAgIG1vdmVUYWJJbmsodHJ1ZSk7CiAg
ICBiaW5kVGFiSW5rSG92ZXIoKTsKICAgIHRyeSB7IG5ldyBSZXNpemVPYnNlcnZlcigoKSA9PiBt
b3ZlVGFiSW5rKHRydWUpKS5vYnNlcnZlKGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0YWJzJykp
OyB9IGNhdGNoIHt9CiAgICB3aW5kb3cuYWRkRXZlbnRMaXN0ZW5lcigncmVzaXplJywgKCkgPT4g
bW92ZVRhYkluayh0cnVlKSk7CiAgICB9CgogICAgZnVuY3Rpb24gdXBkYXRlTW9yZUZvb3Rlcih0
b3RhbCkgewogICAgICAgIGxldCBtb3JlRWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbGlz
dC1tb3JlJyk7CiAgICAgICAgY29uc3QgbG9hZGVkID0gYWxsQ2xpcHMubGVuZ3RoOwogICAgICAg
IGlmIChsb2FkZWQgPj0gdG90YWwpIHsKICAgICAgICAgICAgaWYgKG1vcmVFbCkgbW9yZUVsLnJl
bW92ZSgpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGlmICghbW9yZUVs
KSB7CiAgICAgICAgICAgIG1vcmVFbCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwog
ICAgICAgICAgICBtb3JlRWwuaWQgPSAnbGlzdC1tb3JlJzsKICAgICAgICAgICAgbW9yZUVsLmNs
YXNzTmFtZSA9ICdsaXN0LW1vcmUnOwogICAgICAgICAgICBsaXN0RWwuYXBwZW5kQ2hpbGQobW9y
ZUVsKTsKICAgICAgICB9CiAgICAgICAgbW9yZUVsLnRleHRDb250ZW50ID0gJ+e7p+e7reS4i+a7
keS7juejgeebmOWKoOi9ve+8iCcgKyBsb2FkZWQgKyAnLycgKyB0b3RhbCArICfvvIknOwogICAg
fQoKICAgIGZ1bmN0aW9uIG5hdkxpc3QoKSB7CiAgICAgICAgY29uc3QgYmxvY2tzID0gYnVpbGRQ
aW5uZWRCbG9ja3ModmlzaWJsZUxpc3QoKSk7CiAgICAgICAgY29uc3Qgb3V0ID0gW107CiAgICAg
ICAgZm9yIChjb25zdCBiIG9mIGJsb2NrcykgewogICAgICAgICAgICBpZiAoIWIgfHwgIWIuaXRl
bXMpIGNvbnRpbnVlOwogICAgICAgICAgICBmb3IgKGNvbnN0IGMgb2YgYi5pdGVtcykgb3V0LnB1
c2goYyk7CiAgICAgICAgfQogICAgICAgIHJldHVybiBvdXQ7CiAgICB9CgogICAgZnVuY3Rpb24g
c2VsZWN0QnlJbmRleChpZHgpIHsKICAgICAgICBjb25zdCB2aXMgPSBuYXZMaXN0KCk7CiAgICAg
ICAgaWYgKCF2aXMubGVuZ3RoKSByZXR1cm47CiAgICAgICAgaWR4ID0gTWF0aC5tYXgoMCwgTWF0
aC5taW4odmlzLmxlbmd0aCAtIDEsIGlkeCkpOwogICAgICAgIGlmIChpZHggPj0gdmlzLmxlbmd0
aCAtIDEgJiYgYWxsQ2xpcHMubGVuZ3RoIDwgZGlza1RvdGFsKQogICAgICAgICAgICByZXF1ZXN0
TW9yZSgpOwogICAgICAgIHNlbGVjdGVkSWQgPSB2aXNbTWF0aC5taW4oaWR4LCB2aXMubGVuZ3Ro
IC0gMSldLmlkOwogICAgICAgIHJhbmdlQW5jaG9ySWQgPSBzZWxlY3RlZElkOwogICAgICAgIHJh
bmdlQW5jaG9yQ2xpY2tlZCA9IGZhbHNlOwogICAgICAgIGlmICgrc2VsZWN0ZWRJZCAhPT0gK2xh
c3RQYXN0ZUlkKQogICAgICAgICAgICBsb2NhdGVBY3RpdmUgPSBmYWxzZTsKICAgICAgICB1cGRh
dGVMb2NhdGVCdG4oKTsKICAgICAgICBzeW5jSXRlbUhpZ2hsaWdodCgpOwogICAgICAgIGNvbnN0
IGVsID0gbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5tZy1yb3dbZGF0YS1pZD0iJyArIHNlbGVjdGVk
SWQgKyAnIl0nKQogICAgICAgICAgICB8fCBsaXN0RWwucXVlcnlTZWxlY3RvcignLml0bVtkYXRh
LWlkPSInICsgc2VsZWN0ZWRJZCArICciXScpOwogICAgICAgIGlmIChlbCkgZWwuc2Nyb2xsSW50
b1ZpZXcoeyBibG9jazogJ25lYXJlc3QnIH0pOwogICAgfQoKICAgIGZ1bmN0aW9uIHNlbGVjdGVk
SW5kZXgoKSB7CiAgICAgICAgcmV0dXJuIG5hdkxpc3QoKS5maW5kSW5kZXgoYyA9PiBjLmlkID09
IHNlbGVjdGVkSWQpOwogICAgfQoKICAgIGZ1bmN0aW9uIHN5bmNJdGVtSGlnaGxpZ2h0KCkgewog
ICAgICAgIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5pdG0nKS5mb3JFYWNoKG4gPT4gewog
ICAgICAgICAgICBpZiAobi5jbGFzc0xpc3QuY29udGFpbnMoJ2l0LWdyb3VwJykpIHsKICAgICAg
ICAgICAgICAgIGNvbnN0IHJvd3MgPSBbLi4ubi5xdWVyeVNlbGVjdG9yQWxsKCcubWctcm93Jyld
OwogICAgICAgICAgICAgICAgY29uc3QgaWRzID0gcm93cy5tYXAociA9PiArci5kYXRhc2V0Lmlk
KTsKICAgICAgICAgICAgICAgIGNvbnN0IGFueVNlbCA9IGlkcy5pbmNsdWRlcygrc2VsZWN0ZWRJ
ZCkgfHwgaWRzLnNvbWUoaWQgPT4gbXVsdGlJZHMuaW5jbHVkZXMoaWQpKTsKICAgICAgICAgICAg
ICAgIG4uY2xhc3NMaXN0LnRvZ2dsZSgnc2VsJywgYW55U2VsKTsKICAgICAgICAgICAgICAgIG4u
Y2xhc3NMaXN0LnRvZ2dsZSgnbXVsdGknLCBpZHMuc29tZShpZCA9PiBtdWx0aUlkcy5pbmNsdWRl
cyhpZCkpKTsKICAgICAgICAgICAgICAgIHJvd3MuZm9yRWFjaChyID0+IHsKICAgICAgICAgICAg
ICAgICAgICBjb25zdCBpZCA9ICtyLmRhdGFzZXQuaWQ7CiAgICAgICAgICAgICAgICAgICAgY29u
c3QgaW5NdWx0aSA9IG11bHRpSWRzLmluY2x1ZGVzKGlkKTsKICAgICAgICAgICAgICAgICAgICBy
LmNsYXNzTGlzdC50b2dnbGUoJ3NlbCcsIGlkID09IHNlbGVjdGVkSWQgfHwgaW5NdWx0aSk7CiAg
ICAgICAgICAgICAgICAgICAgci5jbGFzc0xpc3QudG9nZ2xlKCdtdWx0aScsIGluTXVsdGkpOwog
ICAgICAgICAgICAgICAgfSk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0K
ICAgICAgICAgICAgY29uc3QgaWQgPSArbi5kYXRhc2V0LmlkOwogICAgICAgICAgICBjb25zdCBp
bk11bHRpID0gbXVsdGlJZHMuaW5jbHVkZXMoaWQpOwogICAgICAgICAgICBuLmNsYXNzTGlzdC50
b2dnbGUoJ3NlbCcsIGlkID09IHNlbGVjdGVkSWQgfHwgaW5NdWx0aSk7CiAgICAgICAgICAgIG4u
Y2xhc3NMaXN0LnRvZ2dsZSgnbXVsdGknLCBpbk11bHRpKTsKICAgICAgICB9KTsKICAgIH0KICAg
IGZ1bmN0aW9uIHVwZGF0ZU11bHRpQmFkZ2UoKSB7CiAgICAgICAgY29uc3QgZWwgPSBkb2N1bWVu
dC5nZXRFbGVtZW50QnlJZCgnbXVsdGktY250Jyk7CiAgICAgICAgaWYgKG11bHRpSWRzLmxlbmd0
aCA+IDApIHsKICAgICAgICAgICAgZWwudGV4dENvbnRlbnQgPSAn5bey6YCJICcgKyBtdWx0aUlk
cy5sZW5ndGg7CiAgICAgICAgICAgIGVsLmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAgICAgICAgfSBl
bHNlIHsKICAgICAgICAgICAgZWwuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICB9CiAg
ICAgICAgc3luY0l0ZW1IaWdobGlnaHQoKTsKICAgIH0KCiAgICBmdW5jdGlvbiBjbGVhck11bHRp
KHJlc3RvcmVUb0FuY2hvcikgewogICAgICAgIGNvbnN0IGJhY2tJZCA9ICtyYW5nZUFuY2hvcklk
IHx8IDA7CiAgICAgICAgbXVsdGlJZHMgPSBbXTsKICAgICAgICBpZiAocmVzdG9yZVRvQW5jaG9y
ICYmIGJhY2tJZCkKICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IGJhY2tJZDsKICAgICAgICByYW5n
ZUFuY2hvcklkID0gc2VsZWN0ZWRJZCB8fCAwOwogICAgICAgIHJhbmdlQW5jaG9yQ2xpY2tlZCA9
IGZhbHNlOwogICAgICAgIHVwZGF0ZU11bHRpQmFkZ2UoKTsKICAgICAgICBpZiAocmVzdG9yZVRv
QW5jaG9yICYmIHNlbGVjdGVkSWQpIHsKICAgICAgICAgICAgY29uc3QgZWwgPSBsaXN0RWwucXVl
cnlTZWxlY3RvcignLm1nLXJvd1tkYXRhLWlkPSInICsgc2VsZWN0ZWRJZCArICciXScpCiAgICAg
ICAgICAgICAgICB8fCBsaXN0RWwucXVlcnlTZWxlY3RvcignLml0bVtkYXRhLWlkPSInICsgc2Vs
ZWN0ZWRJZCArICciXScpOwogICAgICAgICAgICBpZiAoZWwpIGVsLnNjcm9sbEludG9WaWV3KHsg
YmxvY2s6ICduZWFyZXN0JyB9KTsKICAgICAgICB9CiAgICB9CgoKICAgIC8qIHNoaWZ0LXJhbmdl
LXNlbGVjdC12MSAqLwogICAgbGV0IHJhbmdlQW5jaG9ySWQgPSAwOwogICAgbGV0IHJhbmdlQW5j
aG9yQ2xpY2tlZCA9IGZhbHNlOwogICAgZnVuY3Rpb24gc2VsZWN0UmFuZ2VUbyhpZCkgewogICAg
ICAgIGlkID0gK2lkOwogICAgICAgIGNvbnN0IGxpc3QgPSAodHlwZW9mIG5hdkxpc3QgPT09ICdm
dW5jdGlvbicgPyBuYXZMaXN0KCkgOiB2aXNpYmxlTGlzdCgpKTsKICAgICAgICBjb25zdCBiID0g
bGlzdC5maW5kSW5kZXgoYyA9PiArYy5pZCA9PT0gaWQpOwogICAgICAgIGlmIChiIDwgMCkgcmV0
dXJuOwogICAgICAgIGxldCBhbmNob3IgPSArcmFuZ2VBbmNob3JJZDsKICAgICAgICBsZXQgYSA9
IGxpc3QuZmluZEluZGV4KGMgPT4gK2MuaWQgPT09IGFuY2hvcik7CiAgICAgICAgaWYgKGEgPCAw
KSB7CiAgICAgICAgICAgIGFuY2hvciA9ICtzZWxlY3RlZElkIHx8IGlkOwogICAgICAgICAgICBh
ID0gbGlzdC5maW5kSW5kZXgoYyA9PiArYy5pZCA9PT0gYW5jaG9yKTsKICAgICAgICB9CiAgICAg
ICAgaWYgKGEgPCAwKSB7CiAgICAgICAgICAgIHJhbmdlQW5jaG9ySWQgPSBpZDsgc2VsZWN0ZWRJ
ZCA9IGlkOyBtdWx0aUlkcyA9IFtpZF07IHVwZGF0ZU11bHRpQmFkZ2UoKTsgcmV0dXJuOwogICAg
ICAgIH0KICAgICAgICBpZiAoIXJhbmdlQW5jaG9ySWQgfHwgbGlzdC5maW5kSW5kZXgoYyA9PiAr
Yy5pZCA9PT0gK3JhbmdlQW5jaG9ySWQpIDwgMCkKICAgICAgICAgICAgcmFuZ2VBbmNob3JJZCA9
IGxpc3RbYV0uaWQ7CiAgICAgICAgY29uc3QgbG8gPSBNYXRoLm1pbihhLCBiKSwgaGkgPSBNYXRo
Lm1heChhLCBiKTsKICAgICAgICBtdWx0aUlkcyA9IFtdOwogICAgICAgIGZvciAobGV0IGkgPSBs
bzsgaSA8PSBoaTsgaSsrKSBtdWx0aUlkcy5wdXNoKCtsaXN0W2ldLmlkKTsKICAgICAgICBzZWxl
Y3RlZElkID0gaWQ7CiAgICAgICAgdXBkYXRlTXVsdGlCYWRnZSgpOwogICAgICAgIGNvbnN0IGVs
ID0gbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5tZy1yb3dbZGF0YS1pZD0iJyArIHNlbGVjdGVkSWQg
KyAnIl0nKSB8fCBsaXN0RWwucXVlcnlTZWxlY3RvcignLml0bVtkYXRhLWlkPSInICsgc2VsZWN0
ZWRJZCArICciXScpOwogICAgICAgIGlmIChlbCkgZWwuc2Nyb2xsSW50b1ZpZXcoeyBibG9jazog
J25lYXJlc3QnIH0pOwogICAgfQogICAgZnVuY3Rpb24gc2hvd1NyY1RpcChhbmNob3IsIHRleHQp
IHsKICAgICAgICB0ZXh0ID0gU3RyaW5nKHRleHQgfHwgJycpLnRyaW0oKTsKICAgICAgICBpZiAo
IXRleHQpIHJldHVybjsKICAgICAgICBsZXQgdGlwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQo
J3NyYy10aXAnKTsKICAgICAgICBpZiAoIXRpcCkgewogICAgICAgICAgICB0aXAgPSBkb2N1bWVu
dC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgdGlwLmlkID0gJ3NyYy10aXAnOwog
ICAgICAgICAgICBkb2N1bWVudC5ib2R5LmFwcGVuZENoaWxkKHRpcCk7CiAgICAgICAgfQogICAg
ICAgIHRpcC50ZXh0Q29udGVudCA9IHRleHQ7CiAgICAgICAgdGlwLmNsYXNzTGlzdC5hZGQoJ3No
b3cnKTsKICAgICAgICBjb25zdCByID0gYW5jaG9yLmdldEJvdW5kaW5nQ2xpZW50UmVjdCgpOwog
ICAgICAgIGNvbnN0IHR3ID0gdGlwLm9mZnNldFdpZHRoIHx8IDE2MDsKICAgICAgICBjb25zdCB0
aCA9IHRpcC5vZmZzZXRIZWlnaHQgfHwgMjg7CiAgICAgICAgbGV0IGxlZnQgPSByLnJpZ2h0IC0g
dHc7CiAgICAgICAgbGV0IHRvcCA9IHIudG9wIC0gdGggLSA4OwogICAgICAgIGlmIChsZWZ0IDwg
OCkgbGVmdCA9IDg7CiAgICAgICAgaWYgKGxlZnQgKyB0dyA+IHdpbmRvdy5pbm5lcldpZHRoIC0g
OCkgbGVmdCA9IHdpbmRvdy5pbm5lcldpZHRoIC0gdHcgLSA4OwogICAgICAgIGlmICh0b3AgPCA4
KSB0b3AgPSByLmJvdHRvbSArIDg7CiAgICAgICAgdGlwLnN0eWxlLmxlZnQgPSBsZWZ0ICsgJ3B4
JzsKICAgICAgICB0aXAuc3R5bGUudG9wID0gdG9wICsgJ3B4JzsKICAgICAgICBjbGVhclRpbWVv
dXQodGlwLl9oaWRlVCk7CiAgICAgICAgdGlwLl9oaWRlVCA9IHNldFRpbWVvdXQoKCkgPT4gdGlw
LmNsYXNzTGlzdC5yZW1vdmUoJ3Nob3cnKSwgMjIwMCk7CiAgICB9CiAgICAvKiBpbWctaG92ZXIt
cHJldmlldy12OCAqLwogICAgbGV0IF9faW1nSG92ZXJUaW1lciA9IDAsIF9faW1nSG92ZXJIaWRl
VGltZXIgPSAwLCBfX2ltZ0hvdmVyS2V5ID0gJyc7CiAgICBmdW5jdGlvbiBfX2ltZ0hvdmVyRW5z
dXJlKCkgewogICAgICAgIGxldCBib3ggPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaW1nLWhv
dmVyLXNpZGUnKTsKICAgICAgICBpZiAoIWJveCkgewogICAgICAgICAgICBib3ggPSBkb2N1bWVu
dC5jcmVhdGVFbGVtZW50KCdkaXYnKTsgYm94LmlkID0gJ2ltZy1ob3Zlci1zaWRlJzsKICAgICAg
ICAgICAgY29uc3QgZnJhbWUgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsgZnJhbWUu
Y2xhc3NOYW1lID0gJ2locC1mcmFtZSc7CiAgICAgICAgICAgIGNvbnN0IGltID0gZG9jdW1lbnQu
Y3JlYXRlRWxlbWVudCgnaW1nJyk7IGltLmFsdCA9ICcnOwogICAgICAgICAgICBmcmFtZS5hcHBl
bmRDaGlsZChpbSk7IGJveC5hcHBlbmRDaGlsZChmcmFtZSk7IGRvY3VtZW50LmJvZHkuYXBwZW5k
Q2hpbGQoYm94KTsKICAgICAgICB9CiAgICAgICAgbGV0IHN0ID0gZG9jdW1lbnQuZ2V0RWxlbWVu
dEJ5SWQoJ2ltZy1ob3Zlci1zaWRlLWNzcycpOwogICAgICAgIGlmICghc3QpIHsgc3QgPSBkb2N1
bWVudC5jcmVhdGVFbGVtZW50KCdzdHlsZScpOyBzdC5pZCA9ICdpbWctaG92ZXItc2lkZS1jc3Mn
OyBkb2N1bWVudC5oZWFkLmFwcGVuZENoaWxkKHN0KTsgfQogICAgICAgIHN0LnRleHRDb250ZW50
ID0gIiNpbWctaG92ZXItc2lkZXtwb3NpdGlvbjpmaXhlZDt6LWluZGV4OjEwMDAwMDtyaWdodDo2
cHg7dG9wOjUwJTt0cmFuc2Zvcm06dHJhbnNsYXRlWSgtNTAlKTtwb2ludGVyLWV2ZW50czpub25l
O29wYWNpdHk6MDt2aXNpYmlsaXR5OmhpZGRlbjttYXgtd2lkdGg6bWluKDYyMHB4LDkydncpO21h
eC1oZWlnaHQ6bWluKDkydmgsOTIwcHgpfSNpbWctaG92ZXItc2lkZS5zaG93e29wYWNpdHk6MTt2
aXNpYmlsaXR5OnZpc2libGV9I2ltZy1ob3Zlci1zaWRlIC5paHAtZnJhbWV7cGFkZGluZzozcHg7
YmFja2dyb3VuZDojZmZmO2JvcmRlcjoxcHggc29saWQgI0M1Q0REQztib3JkZXItcmFkaXVzOjJw
eDtib3gtc2hhZG93OjAgNnB4IDE4cHggcmdiYSg0NCw0Niw1NCwuMTIpfSNpbWctaG92ZXItc2lk
ZSBpbWd7ZGlzcGxheTpibG9jazttYXgtd2lkdGg6bWluKDYxMnB4LDkwdncpO21heC1oZWlnaHQ6
bWluKDkwdmgsOTAwcHgpO3dpZHRoOmF1dG87aGVpZ2h0OmF1dG87b2JqZWN0LWZpdDpjb250YWlu
O2JhY2tncm91bmQ6I2ZmZn0iOwogICAgICAgIHJldHVybiBib3g7CiAgICB9CiAgICB3aW5kb3cu
X19pbWdIb3ZlclNob3cgPSBmdW5jdGlvbihmaWxlLCBpZCkgewogICAgICAgIGNvbnN0IGJhcmUg
PSBTdHJpbmcoZmlsZSB8fCAnJykuc3BsaXQoL1tcXFxcL10vKS5wb3AoKTsgaWYgKCFiYXJlKSBy
ZXR1cm47CiAgICAgICAgY29uc3QgYm94ID0gX19pbWdIb3ZlckVuc3VyZSgpOyBjb25zdCBpbWcg
PSBib3gucXVlcnlTZWxlY3RvcignaW1nJyk7IGlmICghaW1nKSByZXR1cm47CiAgICAgICAgYm94
LmNsYXNzTGlzdC5hZGQoJ3Nob3cnKTsKICAgICAgICBpbWcub25lcnJvciA9ICgpID0+IHsKICAg
ICAgICAgICAgaW1nLm9uZXJyb3IgPSAoKSA9PiB7IGltZy5vbmVycm9yID0gbnVsbDsgdHJ5IHsg
Y29uc3QgYyA9IHRodW1iQ2FjaGUgJiYgdGh1bWJDYWNoZS5nZXQoU3RyaW5nKGlkKSk7IGlmIChj
KSBpbWcuc3JjID0gYzsgfSBjYXRjaCAoZSkge30gfTsKICAgICAgICAgICAgaW1nLnNyYyA9IFNU
T1JFX0JBU0UgKyAndGhfJyArIGJhcmUucmVwbGFjZSgvXC5bXi5dKyQvLCAnJykgKyAnLmpwZyc7
CiAgICAgICAgfTsKICAgICAgICBpbWcub25sb2FkID0gKCkgPT4geyBpbWcub25lcnJvciA9IG51
bGw7IH07CiAgICAgICAgaW1nLmRhdGFzZXQuYmFyZSA9IGJhcmU7IGltZy5zcmMgPSBTVE9SRV9C
QVNFICsgYmFyZTsKICAgIH07CiAgICB3aW5kb3cuX19pbWdIb3ZlckNsZWFyVWkgPSBmdW5jdGlv
bigpIHsKICAgICAgICBfX2ltZ0hvdmVyS2V5ID0gJyc7CiAgICAgICAgaWYgKF9faW1nSG92ZXJU
aW1lcikgeyBjbGVhclRpbWVvdXQoX19pbWdIb3ZlclRpbWVyKTsgX19pbWdIb3ZlclRpbWVyID0g
MDsgfQogICAgICAgIGlmIChfX2ltZ0hvdmVySGlkZVRpbWVyKSB7IGNsZWFyVGltZW91dChfX2lt
Z0hvdmVySGlkZVRpbWVyKTsgX19pbWdIb3ZlckhpZGVUaW1lciA9IDA7IH0KICAgICAgICBjb25z
dCBib3ggPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaW1nLWhvdmVyLXNpZGUnKTsgaWYgKGJv
eCkgYm94LmNsYXNzTGlzdC5yZW1vdmUoJ3Nob3cnKTsKICAgICAgICBjb25zdCBpbWcgPSBib3gg
JiYgYm94LnF1ZXJ5U2VsZWN0b3IoJ2ltZycpOwogICAgICAgIGlmIChpbWcpIHsgaW1nLm9ubG9h
ZCA9IG51bGw7IGltZy5vbmVycm9yID0gbnVsbDsgaW1nLnJlbW92ZUF0dHJpYnV0ZSgnc3JjJyk7
IGRlbGV0ZSBpbWcuZGF0YXNldC5iYXJlOyB9CiAgICB9OwogICAgd2luZG93Ll9faW1nSG92ZXJI
aWRlID0gZnVuY3Rpb24oKSB7IHdpbmRvdy5fX2ltZ0hvdmVyQ2xlYXJVaSgpOyB9OwogICAgZnVu
Y3Rpb24gYmluZEltZ0hvdmVyUHJldmlldyhlbCwgaWQsIGZpbGUpIHsKICAgICAgICBpZiAoIWVs
KSByZXR1cm47CiAgICAgICAgY29uc3QgYmFyZSA9IFN0cmluZyhmaWxlIHx8ICcnKS5zcGxpdCgv
W1xcXFwvXS8pLnBvcCgpOyBpZiAoIWJhcmUpIHJldHVybjsKICAgICAgICBjb25zdCBrZXkgPSBT
dHJpbmcoaWQpICsgJ3wnICsgYmFyZTsKICAgICAgICBlbC5zdHlsZS5jdXJzb3IgPSAnem9vbS1p
bic7CiAgICAgICAgZWwuYWRkRXZlbnRMaXN0ZW5lcignbW91c2VlbnRlcicsICgpID0+IHsKICAg
ICAgICAgICAgaWYgKF9faW1nSG92ZXJIaWRlVGltZXIpIHsgY2xlYXJUaW1lb3V0KF9faW1nSG92
ZXJIaWRlVGltZXIpOyBfX2ltZ0hvdmVySGlkZVRpbWVyID0gMDsgfQogICAgICAgICAgICBfX2lt
Z0hvdmVyS2V5ID0ga2V5OwogICAgICAgICAgICBpZiAoX19pbWdIb3ZlclRpbWVyKSBjbGVhclRp
bWVvdXQoX19pbWdIb3ZlclRpbWVyKTsKICAgICAgICAgICAgX19pbWdIb3ZlclRpbWVyID0gc2V0
VGltZW91dCgoKSA9PiB7IGlmIChfX2ltZ0hvdmVyS2V5ID09PSBrZXkpIHRyeSB7IHdpbmRvdy5f
X2ltZ0hvdmVyU2hvdyhiYXJlLCBpZCk7IH0gY2F0Y2ggKGUpIHt9IH0sIDYwKTsKICAgICAgICB9
KTsKICAgICAgICBlbC5hZGRFdmVudExpc3RlbmVyKCdtb3VzZWxlYXZlJywgKCkgPT4gewogICAg
ICAgICAgICBpZiAoX19pbWdIb3ZlclRpbWVyKSB7IGNsZWFyVGltZW91dChfX2ltZ0hvdmVyVGlt
ZXIpOyBfX2ltZ0hvdmVyVGltZXIgPSAwOyB9CiAgICAgICAgICAgIF9faW1nSG92ZXJIaWRlVGlt
ZXIgPSBzZXRUaW1lb3V0KCgpID0+IHsgaWYgKCFfX2ltZ0hvdmVyS2V5IHx8IF9faW1nSG92ZXJL
ZXkgPT09IGtleSkgd2luZG93Ll9faW1nSG92ZXJIaWRlKCk7IH0sIDcwKTsKICAgICAgICB9KTsK
ICAgIH0KICAgIGZ1bmN0aW9uIGhhbmRsZUl0ZW1DbGljayhlLCBjKSB7CiAgICAgICAgaWYgKGUu
c2hpZnRLZXkpIHsKICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOyBlLnN0b3BQcm9wYWdh
dGlvbigpOwogICAgICAgICAgICBjb25zdCBsaXN0ID0gKHR5cGVvZiBuYXZMaXN0ID09PSAnZnVu
Y3Rpb24nID8gbmF2TGlzdCgpIDogdmlzaWJsZUxpc3QoKSk7CiAgICAgICAgICAgIGNvbnN0IGFu
Y2hvck9rID0gcmFuZ2VBbmNob3JDbGlja2VkICYmIHJhbmdlQW5jaG9ySWQgJiYgbGlzdC5zb21l
KHggPT4gK3guaWQgPT09ICtyYW5nZUFuY2hvcklkKTsKICAgICAgICAgICAgaWYgKCFhbmNob3JP
aykgcmFuZ2VBbmNob3JJZCA9IHNlbGVjdGVkSWQgfHwgYy5pZDsKICAgICAgICAgICAgcmFuZ2VB
bmNob3JDbGlja2VkID0gdHJ1ZTsKICAgICAgICAgICAgc2VsZWN0UmFuZ2VUbyhjLmlkKTsKICAg
ICAgICAgICAgcmV0dXJuIHRydWU7CiAgICAgICAgfQogICAgICAgIGlmIChlLmN0cmxLZXkgfHwg
ZS5tZXRhS2V5KSB7CiAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsgZS5zdG9wUHJvcGFn
YXRpb24oKTsKICAgICAgICAgICAgdG9nZ2xlTXVsdGkoYy5pZCk7CiAgICAgICAgICAgIHJldHVy
biB0cnVlOwogICAgICAgIH0KICAgICAgICByYW5nZUFuY2hvcklkID0gYy5pZDsKICAgICAgICBy
YW5nZUFuY2hvckNsaWNrZWQgPSB0cnVlOwogICAgICAgIHJldHVybiBmYWxzZTsKICAgIH0KICAg
IGZ1bmN0aW9uIHRvZ2dsZU11bHRpKGlkKSB7CiAgICAgICAgaWQgPSAraWQ7CiAgICAgICAgY29u
c3QgaSA9IG11bHRpSWRzLmluZGV4T2YoaWQpOwogICAgICAgIGlmIChpID49IDApIG11bHRpSWRz
LnNwbGljZShpLCAxKTsKICAgICAgICBlbHNlIG11bHRpSWRzLnB1c2goaWQpOwogICAgICAgIHNl
bGVjdGVkSWQgPSBpZDsKICAgICAgICByYW5nZUFuY2hvcklkID0gaWQ7CiAgICAgICAgcmFuZ2VB
bmNob3JDbGlja2VkID0gdHJ1ZTsKICAgICAgICB1cGRhdGVNdWx0aUJhZGdlKCk7CiAgICB9Cgog
ICAgZnVuY3Rpb24gcmVuZGVyKCkgewogICAgICAgIGhpZGVQYXRoVGlwKCk7CgogICAgICAgIGNv
bnN0IHZpc2libGUgPSB2aXNpYmxlTGlzdCgpOwogICAgICAgIGNvbnN0IHBpbm5lZE4gPSBhbGxD
bGlwcy5maWx0ZXIoYyA9PiBpc1Bpbm5lZChjKSkubGVuZ3RoOwogICAgICAgIGNvbnN0IHBpbkNu
dCAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncGluLWNudCcpOwogICAgICAgIHBpbkNudC50
ZXh0Q29udGVudCAgID0gcGlubmVkTjsKICAgICAgICBwaW5DbnQuc3R5bGUuZGlzcGxheSA9IHBp
bm5lZE4gPyAnJyA6ICdub25lJzsKICAgICAgICBjb25zdCBsb2FkZWQgPSBhbGxDbGlwcy5sZW5n
dGg7CiAgICAgICAgY29uc3Qgc2hvd24gPSB2aXNpYmxlLmxlbmd0aDsKICAgICAgICBjb25zdCBz
aG93VG90YWwgPSBkaXNrVG90YWwgPiAwID8gZGlza1RvdGFsIDogKGxvYWRlZCB8fCAwKTsKICAg
ICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYmFyLXR4dCcpLnRleHRDb250ZW50ID0KICAg
ICAgICAgICAgZGlza1RvdGFsID4gbG9hZGVkID8gKHNob3duICsgJyAvICcgKyBzaG93VG90YWwg
KyAnIOadoScpIDogKHNob3dUb3RhbCArICcg5p2hJyk7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxl
bWVudEJ5SWQoJ2VtcHR5LXR4dCcpLnRleHRDb250ZW50ID0gRU1QVFlfTVNHW2N1clRhYl0gfHwg
RU1QVFlfTVNHLmFsbDsKCiAgICAgICAgY29uc3QgaWRTZXQgPSBuZXcgU2V0KGFsbENsaXBzLm1h
cChjID0+ICtjLmlkKSk7CiAgICAgICAgbXVsdGlJZHMgPSBtdWx0aUlkcy5maWx0ZXIoaWQgPT4g
aWRTZXQuaGFzKGlkKSk7CiAgICAgICAgdXBkYXRlTXVsdGlCYWRnZSgpOwoKICAgICAgICBjb25z
dCBzaG93biA9IHZpc2libGU7CgogICAgICAgIGxpc3RFbC5xdWVyeVNlbGVjdG9yQWxsKCcuaXRt
LCAjbGlzdC1tb3JlJykuZm9yRWFjaChlID0+IGUucmVtb3ZlKCkpOwogICAgICAgIGlmIChib290
TG9hZGluZykgewogICAgICAgICAgICBpZiAoc2tlbEVsKSBza2VsRWwuY2xhc3NMaXN0LmFkZCgn
b24nKTsKICAgICAgICAgICAgZW1wdHlFbC5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAg
ICAgICB1cGRhdGVUb3BCdG4oKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAg
ICBpZiAoc2tlbEVsKSBza2VsRWwuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICBpZiAo
IXZpc2libGUubGVuZ3RoKSB7CiAgICAgICAgICAgIGlmIChzZWxlY3RGaXJzdE9uU2hvdykgewog
ICAgICAgICAgICAgICAgc2VsZWN0Rmlyc3RPblNob3cgPSBmYWxzZTsKICAgICAgICAgICAgICAg
IHNlbGVjdGVkSWQgPSAwOwogICAgICAgICAgICAgICAgY2xlYXJNdWx0aSgpOwogICAgICAgICAg
ICAgICAgbGlzdEVsLnNjcm9sbFRvcCA9IDA7CiAgICAgICAgICAgIH0KICAgICAgICAgICAgZW1w
dHlFbC5jbGFzc0xpc3QuYWRkKCdvbicpOwogICAgICAgICAgICB1cGRhdGVUb3BCdG4oKTsKICAg
ICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBlbXB0eUVsLmNsYXNzTGlzdC5yZW1v
dmUoJ29uJyk7CiAgICAgICAgY29uc3QgZnJhZyA9IGRvY3VtZW50LmNyZWF0ZURvY3VtZW50RnJh
Z21lbnQoKTsKICAgICAgICBjb25zdCBibG9ja3MgPSBidWlsZFBpbm5lZEJsb2NrcyhzaG93bik7
CiAgICAgICAgbGV0IG51bSA9IDA7CiAgICAgICAgYmxvY2tzLmZvckVhY2goYiA9PiB7CiAgICAg
ICAgICAgIG51bSArPSAxOwogICAgICAgICAgICBpZiAoYi5raW5kID09PSAnZ3JvdXAnICYmIGIu
aXRlbXMubGVuZ3RoID4gMSkKICAgICAgICAgICAgICAgIGZyYWcuYXBwZW5kQ2hpbGQobWFrZUdy
b3VwSXRlbShiLml0ZW1zLCBudW0pKTsKICAgICAgICAgICAgZWxzZQogICAgICAgICAgICAgICAg
ZnJhZy5hcHBlbmRDaGlsZChtYWtlSXRlbShiLml0ZW1zWzBdLCBudW0pKTsKICAgICAgICB9KTsK
ICAgICAgICBsaXN0RWwuYXBwZW5kQ2hpbGQoZnJhZyk7CiAgICAgICAgdXBkYXRlTW9yZUZvb3Rl
cihkaXNrVG90YWwpOwogICAgICAgIGlmIChzZWxlY3RGaXJzdE9uU2hvdykgewogICAgICAgICAg
ICBzZWxlY3RGaXJzdE9uU2hvdyA9IGZhbHNlOwogICAgICAgICAgICBzZWxlY3RlZElkID0gdmlz
aWJsZVswXS5pZDsKICAgICAgICAgICAgY2xlYXJNdWx0aSgpOwogICAgICAgICAgICBsaXN0RWwu
c2Nyb2xsVG9wID0gMDsKICAgICAgICB9IGVsc2UgaWYgKCF2aXNpYmxlLnNvbWUoYyA9PiBjLmlk
ID09IHNlbGVjdGVkSWQpKSB7CiAgICAgICAgICAgIHNlbGVjdGVkSWQgPSB2aXNpYmxlWzBdLmlk
OwogICAgICAgICAgICByYW5nZUFuY2hvcklkID0gc2VsZWN0ZWRJZDsKICAgICAgICAgICAgcmFu
Z2VBbmNob3JDbGlja2VkID0gZmFsc2U7CiAgICAgICAgfSBlbHNlIGlmICghcmFuZ2VBbmNob3JJ
ZCkgewogICAgICAgICAgICByYW5nZUFuY2hvcklkID0gc2VsZWN0ZWRJZDsKICAgICAgICB9CiAg
ICAgICAgc3luY0l0ZW1IaWdobGlnaHQoKTsKICAgICAgICB1cGRhdGVUb3BCdG4oKTsKICAgICAg
ICBpZiAod2luZG93Ll9fcGVuZGluZ0p1bXBJZCkgewogICAgICAgICAgICBjb25zdCBqaWQgPSAr
d2luZG93Ll9fcGVuZGluZ0p1bXBJZDsKICAgICAgICAgICAgY29uc3QgZWwgPSBsaXN0RWwucXVl
cnlTZWxlY3RvcignLm1nLXJvd1tkYXRhLWlkPSInICsgamlkICsgJyJdJykgfHwgbGlzdEVsLnF1
ZXJ5U2VsZWN0b3IoJy5pdG1bZGF0YS1pZD0iJyArIGppZCArICciXScpOwogICAgICAgICAgICBp
ZiAoZWwpIHsKICAgICAgICAgICAgICAgIHdpbmRvdy5fX3BlbmRpbmdKdW1wSWQgPSAwOwogICAg
ICAgICAgICAgICAgd2luZG93Ll9fanVtcExvYWRUcmllcyA9IDA7CiAgICAgICAgICAgICAgICBz
ZWxlY3RlZElkID0gamlkOwogICAgICAgICAgICAgICAgcmVxdWVzdEFuaW1hdGlvbkZyYW1lKCgp
ID0+IHsKICAgICAgICAgICAgICAgICAgICBjb25zdCBub2RlID0gbGlzdEVsLnF1ZXJ5U2VsZWN0
b3IoJy5tZy1yb3dbZGF0YS1pZD0iJyArIGppZCArICciXScpIHx8IGxpc3RFbC5xdWVyeVNlbGVj
dG9yKCcuaXRtW2RhdGEtaWQ9IicgKyBqaWQgKyAnIl0nKTsKICAgICAgICAgICAgICAgICAgICBp
ZiAoIW5vZGUpIHJldHVybjsKICAgICAgICAgICAgICAgICAgICBub2RlLnNjcm9sbEludG9WaWV3
KHsgYmxvY2s6ICdjZW50ZXInIH0pOwogICAgICAgICAgICAgICAgICAgIG5vZGUuY2xhc3NMaXN0
LmFkZCgnanVtcC1mbGFzaCcpOwogICAgICAgICAgICAgICAgICAgIHNldFRpbWVvdXQoKCkgPT4g
bm9kZS5jbGFzc0xpc3QucmVtb3ZlKCdqdW1wLWZsYXNoJyksIDkwMCk7CiAgICAgICAgICAgICAg
ICAgICAgc3luY0l0ZW1IaWdobGlnaHQoKTsKICAgICAgICAgICAgICAgIH0pOwogICAgICAgICAg
ICB9IGVsc2UgaWYgKGFsbENsaXBzLmxlbmd0aCA8IGRpc2tUb3RhbCAmJiAod2luZG93Ll9fanVt
cExvYWRUcmllcyB8fCAwKSA8IDQwKSB7CiAgICAgICAgICAgICAgICB3aW5kb3cuX19qdW1wTG9h
ZFRyaWVzID0gKHdpbmRvdy5fX2p1bXBMb2FkVHJpZXMgfHwgMCkgKyAxOwogICAgICAgICAgICAg
ICAgcmVxdWVzdE1vcmUoKTsKICAgICAgICAgICAgfSBlbHNlIGlmIChjdXJUYWIgIT09ICdhbGwn
ICYmICF3aW5kb3cuX19qdW1wRmVsbEJhY2spIHsKICAgICAgICAgICAgICAgIC8vIEl0ZW0gZ29u
ZSBmcm9tIHRoaXMgdGFiIChlLmcuIHVucGlubmVkKSDigJQgZmFsbCBiYWNrIHRvIOWFqOmDqCBv
bmNlCiAgICAgICAgICAgICAgICB3aW5kb3cuX19qdW1wRmVsbEJhY2sgPSB0cnVlOwogICAgICAg
ICAgICAgICAgd2luZG93Ll9fanVtcExvYWRUcmllcyA9IDA7CiAgICAgICAgICAgICAgICBjdXJU
YWIgPSAnYWxsJzsKICAgICAgICAgICAgICAgIG1hcmtUYWIoJ2FsbCcpOwogICAgICAgICAgICAg
ICAgcmVxdWVzdFZpZXcoKTsKICAgICAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgICAgIHdp
bmRvdy5fX3BlbmRpbmdKdW1wSWQgPSAwOwogICAgICAgICAgICAgICAgd2luZG93Ll9fanVtcExv
YWRUcmllcyA9IDA7CiAgICAgICAgICAgICAgICBpZiAoYWxsQ2xpcHMuc29tZShjID0+ICtjLmlk
ID09PSBqaWQpKQogICAgICAgICAgICAgICAgICAgIHNlbGVjdGVkSWQgPSBqaWQ7CiAgICAgICAg
ICAgICAgICBzeW5jSXRlbUhpZ2hsaWdodCgpOwogICAgICAgICAgICB9CiAgICAgICAgfQogICAg
ICAgIHJlcXVlc3RBbmltYXRpb25GcmFtZSgoKSA9PiB7CiAgICAgICAgICAgIGlmIChhbGxDbGlw
cy5sZW5ndGggPCBkaXNrVG90YWwKICAgICAgICAgICAgICAgICYmIGxpc3RFbC5zY3JvbGxIZWln
aHQgPD0gbGlzdEVsLmNsaWVudEhlaWdodCArIDIwKQogICAgICAgICAgICAgICAgcmVxdWVzdE1v
cmUoKTsKICAgICAgICB9KTsKICAgIH0KCiAgICBjb25zdCBTVkcgPSB7CiAgICAgICAgdGV4dDog
ICBgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENv
bG9yIiBzdHJva2Utd2lkdGg9IjIiPjxwYXRoIGQ9Ik00IDdWNGgxNnYzTTkgMjBoNk0xMiA0djE2
Ii8+PC9zdmc+YCwKICAgICAgICBtZDogICAgIGA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmls
bD0iY3VycmVudENvbG9yIj48dGV4dCB4PSIxMiIgeT0iMTciIHRleHQtYW5jaG9yPSJtaWRkbGUi
IGZvbnQtc2l6ZT0iMTYiIGZvbnQtd2VpZ2h0PSI4MDAiIGZvbnQtZmFtaWx5PSJTZWdvZSBVSSxz
YW5zLXNlcmlmIj5NPC90ZXh0Pjwvc3ZnPmAsCiAgICAgICAgaW1hZ2U6ICBgPHN2ZyB2aWV3Qm94
PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lk
dGg9IjEuOCI+PHJlY3QgeD0iMyIgeT0iNSIgd2lkdGg9IjE4IiBoZWlnaHQ9IjE0IiByeD0iMiIv
PjxjaXJjbGUgY3g9IjguNSIgY3k9IjEwIiByPSIxLjUiIGZpbGw9ImN1cnJlbnRDb2xvciIgc3Ry
b2tlPSJub25lIi8+PHBhdGggZD0iTTMgMTZsNS01IDQgNCAzLTMgNiA2Ii8+PC9zdmc+YCwKICAg
ICAgICB2aWRlbzogIGA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tl
PSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44Ij48cmVjdCB4PSIzIiB5PSI2IiB3aWR0
aD0iMTQiIGhlaWdodD0iMTIiIHJ4PSIyIi8+PHBhdGggZD0iTTE3IDkuNWw0LTIuNXYxMGwtNC0y
LjVWOS41eiIgZmlsbD0iY3VycmVudENvbG9yIiBzdHJva2U9Im5vbmUiLz48cGF0aCBkPSJNOC41
IDEwLjJ2My42bDMuMi0xLjgtMy4yLTEuOHoiIGZpbGw9ImN1cnJlbnRDb2xvciIgc3Ryb2tlPSJu
b25lIi8+PC9zdmc+YCwKICAgICAgICBmb2xkZXI6IGA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIg
ZmlsbD0iY3VycmVudENvbG9yIj48cGF0aCBkPSJNMTAgNEg0Yy0xLjEgMC0yIC45LTIgMnYxMmMw
IDEuMS45IDIgMiAyaDE2YzEuMSAwIDItLjkgMi0yVjhjMC0xLjEtLjktMi0yLTJoLThsLTItMnoi
Lz48L3N2Zz5gLAogICAgICAgIHppcDogICAgYDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxs
PSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxwYXRoIGQ9
Ik02IDNoOWw1IDV2MTNhMSAxIDAgMCAxLTEgMUg2YTEgMSAwIDAgMS0xLTFWNGExIDEgMCAwIDEg
MS0xeiIvPjxwYXRoIGQ9Ik0xNCAzdjZoNiIvPjwvc3ZnPmAsCiAgICAgICAgYWhrOiAgICBgPHN2
ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9ImN1cnJlbnRDb2xvciI+PHRleHQgeD0iMTIiIHk9
IjE3IiB0ZXh0LWFuY2hvcj0ibWlkZGxlIiBmb250LXNpemU9IjE0IiBmb250LXdlaWdodD0iNzAw
Ij5IPC90ZXh0Pjwvc3ZnPmAsCiAgICAgICAgbG5rOiAgICBgPHN2ZyB2aWV3Qm94PSIwIDAgMjQg
MjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCI+
PHBhdGggZD0iTTEwIDEzYTUgNSAwIDAgMCA3LjA3IDBsMi4xMi0yLjEyYTUgNSAwIDAgMC03LjA3
LTcuMDdMMTEgNSIvPjxwYXRoIGQ9Ik0xNCAxMWE1IDUgMCAwIDAtNy4wNyAwTDQuOCAxMy4xMmE1
IDUgMCAxIDAgNy4wNyA3LjA3TDEzIDE5Ii8+PC9zdmc+YCwKICAgICAgICBkb2M6ICAgIGA8c3Zn
IHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0
cm9rZS13aWR0aD0iMS44Ij48cGF0aCBkPSJNNyAzaDdsNSA1djEzYTEgMSAwIDAgMS0xIDFIN2Ex
IDEgMCAwIDEtMS0xVjRhMSAxIDAgMCAxIDEtMXoiLz48cGF0aCBkPSJNMTQgM3Y2aDYiLz48L3N2
Zz5gLAogICAgICAgIG11bHRpOiAgYDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25l
IiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxyZWN0IHg9IjciIHk9
IjciIHdpZHRoPSIxMiIgaGVpZ2h0PSIxNCIgcng9IjEuNSIvPjxwYXRoIGQ9Ik01IDE3VjVhMSAx
IDAgMCAxIDEtMWgxMCIvPjwvc3ZnPmAKICAgIH07CgogICAgZnVuY3Rpb24gZmlsZUV4dChwYXRo
KSB7CiAgICAgICAgY29uc3QgYmFzZSA9IFN0cmluZyhwYXRoIHx8ICcnKS5zcGxpdCgvW1xcL10v
KS5wb3AoKSB8fCAnJzsKICAgICAgICBjb25zdCBpID0gYmFzZS5sYXN0SW5kZXhPZignLicpOwog
ICAgICAgIHJldHVybiBpID4gMCA/IGJhc2Uuc2xpY2UoaSArIDEpLnRvTG93ZXJDYXNlKCkgOiAn
JzsKICAgIH0KICAgIGNvbnN0IGlzSW1hZ2VFeHQgPSBlID0+IFsncG5nJywnanBnJywnanBlZycs
J2dpZicsJ3dlYnAnLCdibXAnLCdpY28nLCd0aWYnLCd0aWZmJywnc3ZnJ10uaW5jbHVkZXMoZSk7
CiAgICBjb25zdCBpc1ZpZGVvRXh0ID0gZSA9PiBbJ21wNCcsJ21rdicsJ2F2aScsJ21vdicsJ3dt
dicsJ2ZsdicsJ3dlYm0nLCdtNHYnLCdtcGVnJywnbXBnJywndHMnLCdtMnRzJywnM2dwJywncm0n
LCdybXZiJ10uaW5jbHVkZXMoZSk7CiAgICBjb25zdCBpc1ppcEV4dCAgID0gZSA9PiBbJ3ppcCcs
J3JhcicsJzd6JywndGFyJywnZ3onLCdiejInXS5pbmNsdWRlcyhlKTsKCiAgICBmdW5jdGlvbiBp
Y29uRm9yRmlsZXMoZmlsZXMpIHsKICAgICAgICBpZiAoIWZpbGVzLmxlbmd0aCkgICAgcmV0dXJu
IHsgY2xzOiAnZmlsZSBmdC1kb2MnLCBzdmc6IFNWRy5kb2MgfTsKICAgICAgICBpZiAoZmlsZXMu
bGVuZ3RoID4gMSkgcmV0dXJuIHsgY2xzOiAnZmlsZSBmdC1sbmsnLCBzdmc6IFNWRy5tdWx0aSB9
OwogICAgICAgIGNvbnN0IGV4dCA9IGZpbGVFeHQoZmlsZXNbMF0pOwogICAgICAgIGlmICghZXh0
KSAgICAgICAgICAgICAgcmV0dXJuIHsgY2xzOiAnZmlsZSBmdC1kaXInLCBzdmc6IFNWRy5mb2xk
ZXIgfTsKICAgICAgICBpZiAoaXNJbWFnZUV4dChleHQpKSAgIHJldHVybiB7IGNsczogJ2ZpbGUg
ZnQtaW1nJywgc3ZnOiBTVkcuaW1hZ2UgfTsKICAgICAgICBpZiAoaXNWaWRlb0V4dChleHQpKSAg
IHJldHVybiB7IGNsczogJ2ZpbGUgZnQtdmlkJywgc3ZnOiAoU1ZHLnZpZGVvIHx8IFNWRy5kb2Mp
IH07CiAgICAgICAgaWYgKGlzWmlwRXh0KGV4dCkpICAgICByZXR1cm4geyBjbHM6ICdmaWxlIGZ0
LXppcCcsIHN2ZzogU1ZHLnppcCB9OwogICAgICAgIGlmIChleHQgPT09ICdhaGsnKSAgICAgcmV0
dXJuIHsgY2xzOiAnZmlsZSBmdC1haGsnLCBzdmc6IFNWRy5haGsgfTsKICAgICAgICBpZiAoZXh0
ID09PSAnbG5rJykgICAgIHJldHVybiB7IGNsczogJ2ZpbGUgZnQtbG5rJywgc3ZnOiBTVkcubG5r
IH07CiAgICAgICAgcmV0dXJuIHsgY2xzOiAnZmlsZSBmdC1kb2MnLCBzdmc6IFNWRy5kb2MgfTsK
ICAgIH0KCiAgICBmdW5jdGlvbiBmYXZHcm91cE9mKGMpIHsKICAgICAgICByZXR1cm4gU3RyaW5n
KGMgJiYgYy5mYXZHcm91cCB8fCAnJykudHJpbSgpOwogICAgfQogICAgZnVuY3Rpb24gY2xpcENv
bnRlbnRQcmV2aWV3KGMpIHsKICAgICAgICBjb25zdCB0eXBlID0gbm9ybVR5cGUoYy50eXBlKTsK
ICAgICAgICBpZiAodHlwZSA9PT0gJ2ltYWdlJykgcmV0dXJuICdb5Zu+5YOPXScgKyAoYy53aWR0
aCAmJiBjLmhlaWdodCA/ICgnICcgKyBjLndpZHRoICsgJ8OXJyArIGMuaGVpZ2h0KSA6ICcnKTsK
ICAgICAgICBpZiAodHlwZSA9PT0gJ2ZpbGUnKSB7CiAgICAgICAgICAgIGNvbnN0IGZpbGVzID0g
U3RyaW5nKGMucHJldmlldyB8fCBjLmRhdGEgfHwgJycpLnNwbGl0KC9ccj9cbi8pLmZpbHRlcihC
b29sZWFuKTsKICAgICAgICAgICAgcmV0dXJuIGZpbGVzLm1hcChmID0+IGYuc3BsaXQoL1tcXC9d
LykucG9wKCkpLmpvaW4oJyDCtyAnKSB8fCAnW+aWh+S7tl0nOwogICAgICAgIH0KICAgICAgICBs
ZXQgX3AgPSBTdHJpbmcoYy5wcmV2aWV3IHx8IGMuZGF0YSB8fCAnJyk7CiAgICAgICAgeyBjb25z
dCBfbiA9IE51bWJlcihjLmNoYXJDb3VudCkgfHwgMDsgaWYgKF9uID4gX3AubGVuZ3RoICYmIF9w
Lmxlbmd0aCkgX3AgKz0gJy4uLic7IH0KICAgICAgICByZXR1cm4gX3A7CiAgICB9CiAgICBmdW5j
dGlvbiBidWlsZFBpbm5lZEJsb2NrcyhsaXN0KSB7CiAgICAgICAgY29uc3QgdXNlZCA9IG5ldyBT
ZXQoKTsKICAgICAgICBjb25zdCBvdXQgPSBbXTsKICAgICAgICBmb3IgKGNvbnN0IGMgb2YgbGlz
dCkgewogICAgICAgICAgICBpZiAodXNlZC5oYXMoK2MuaWQpKSBjb250aW51ZTsKICAgICAgICAg
ICAgY29uc3QgZ2lkID0gZmF2R3JvdXBPZihjKTsKICAgICAgICAgICAgaWYgKCFnaWQpIHsKICAg
ICAgICAgICAgICAgIHVzZWQuYWRkKCtjLmlkKTsKICAgICAgICAgICAgICAgIG91dC5wdXNoKHsg
a2luZDogJ3NpbmdsZScsIGl0ZW1zOiBbY10gfSk7CiAgICAgICAgICAgICAgICBjb250aW51ZTsK
ICAgICAgICAgICAgfQogICAgICAgICAgICBjb25zdCBtZW1iZXJzID0gbGlzdC5maWx0ZXIoeCA9
PiBmYXZHcm91cE9mKHgpID09PSBnaWQpOwogICAgICAgICAgICBtZW1iZXJzLmZvckVhY2gobSA9
PiB1c2VkLmFkZCgrbS5pZCkpOwogICAgICAgICAgICBpZiAobWVtYmVycy5sZW5ndGggPCAyKQog
ICAgICAgICAgICAgICAgb3V0LnB1c2goeyBraW5kOiAnc2luZ2xlJywgaXRlbXM6IFttZW1iZXJz
WzBdIHx8IGNdIH0pOwogICAgICAgICAgICBlbHNlCiAgICAgICAgICAgICAgICBvdXQucHVzaCh7
IGtpbmQ6ICdncm91cCcsIGdpZCwgaXRlbXM6IG1lbWJlcnMgfSk7CiAgICAgICAgfQogICAgICAg
IHJldHVybiBvdXQ7CiAgICB9CiAgICBmdW5jdGlvbiBfX3ByZXBQYXN0ZSgpIHsKICAgICAgICB0
cnkgewogICAgICAgICAgICBjb25zdCBzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJj
aCcpOwogICAgICAgICAgICBpZiAocyAmJiBkb2N1bWVudC5hY3RpdmVFbGVtZW50ID09PSBzKSB0
cnkgeyBzLmJsdXIoKTsgfSBjYXRjaCB7fQogICAgICAgICAgICBpZiAod2luZG93LmdldFNlbGVj
dGlvbikgd2luZG93LmdldFNlbGVjdGlvbigpLnJlbW92ZUFsbFJhbmdlcygpOwogICAgICAgIH0g
Y2F0Y2gge30KICAgIH0KICAgIGZ1bmN0aW9uIHBhc3RlT25lKGMpIHsKICAgICAgICBfX3ByZXBQ
YXN0ZSgpOwogICAgICAgIHNlbGVjdGVkSWQgPSBjLmlkOwogICAgICAgIGlmIChtdWx0aUlkcy5s
ZW5ndGgpIGNsZWFyTXVsdGkoKTsKICAgICAgICBzeW5jSXRlbUhpZ2hsaWdodCgpOwogICAgICAg
IG1hcmtQYXN0ZWRMb2NhbChjLmlkKTsKICAgICAgICBhaGsoJ3Bhc3RlJywgU3RyaW5nKGMuaWQp
KTsKICAgIH0KICAgIGZ1bmN0aW9uIGlzSXRlbUNocm9tZVRhcmdldCh0KSB7CiAgICAgICAgcmV0
dXJuICEhKHQgJiYgdC5jbG9zZXN0ICYmIHQuY2xvc2VzdCgnLmktZXhwYW5kLWJ0biwgLmktc3Jj
LWljbywgLm1nLXNyYywgLmZkLWJ0biwgLmZkLXBhdGgsIGJ1dHRvbiwgYSwgaW5wdXQnKSk7CiAg
ICB9CiAgICBmdW5jdGlvbiBiZWdpblBhc3RlRnJvbUl0ZW0oZSwgYykgewogICAgICAgIGlmIChl
LmJ1dHRvbiAhPSBudWxsICYmIGUuYnV0dG9uICE9PSAwKSByZXR1cm47CiAgICAgICAgaWYgKGlz
SXRlbUNocm9tZVRhcmdldChlLnRhcmdldCkpIHJldHVybjsKICAgICAgICBpZiAoaGFuZGxlSXRl
bUNsaWNrKGUsIGMpKQogICAgICAgICAgICByZXR1cm47CiAgICAgICAgX19wcmVwUGFzdGUoKTsK
ICAgICAgICBzZWxlY3RlZElkID0gYy5pZDsKICAgICAgICByYW5nZUFuY2hvcklkID0gYy5pZDsK
ICAgICAgICBpZiAobXVsdGlJZHMubGVuZ3RoID4gMCAmJiBtdWx0aUlkcy5pbmNsdWRlcygrYy5p
ZCkpIHsKICAgICAgICAgICAgY29uc3QgaWRzID0gbXVsdGlJZHMuc2xpY2UoKTsKICAgICAgICAg
ICAgY2xlYXJNdWx0aSgpOwogICAgICAgICAgICBtYXJrUGFzdGVkTG9jYWwoaWRzKTsKICAgICAg
ICAgICAgaWYgKGlkcy5sZW5ndGggPiAxKSBhaGsoJ3Bhc3RlTWFueScsIGlkcy5qb2luKCcsJykp
OwogICAgICAgICAgICBlbHNlIGFoaygncGFzdGUnLCBTdHJpbmcoaWRzWzBdKSk7CiAgICAgICAg
ICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgaWYgKG11bHRpSWRzLmxlbmd0aCkgY2xlYXJN
dWx0aSgpOwogICAgICAgIHN5bmNJdGVtSGlnaGxpZ2h0KCk7CiAgICAgICAgbWFya1Bhc3RlZExv
Y2FsKGMuaWQpOwogICAgICAgIGFoaygncGFzdGUnLCBTdHJpbmcoYy5pZCkpOwogICAgfQogICAg
ZnVuY3Rpb24gbWFrZUdyb3VwSXRlbShpdGVtcywgaWR4KSB7CiAgICAgICAgY29uc3QgZWwgPSBk
b2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICBlbC5jbGFzc05hbWUgPSAnaXRt
IGl0LWdyb3VwJwogICAgICAgICAgICArIChpdGVtcy5zb21lKGMgPT4gK2MuaWQgPT09ICtzZWxl
Y3RlZElkKSA/ICcgc2VsJyA6ICcnKQogICAgICAgICAgICArIChpdGVtcy5zb21lKGMgPT4gbXVs
dGlJZHMuaW5jbHVkZXMoK2MuaWQpKSA/ICcgbXVsdGknIDogJycpOwogICAgICAgIGVsLmRhdGFz
ZXQuZ3JvdXAgPSBmYXZHcm91cE9mKGl0ZW1zWzBdKSB8fCAnJzsKICAgICAgICBlbC5kYXRhc2V0
LmlkID0gaXRlbXNbMF0uaWQ7CgogICAgICAgIGNvbnN0IGhlYWQgPSBkb2N1bWVudC5jcmVhdGVF
bGVtZW50KCdkaXYnKTsKICAgICAgICBoZWFkLmNsYXNzTmFtZSA9ICdtZy1oZWFkJzsKICAgICAg
ICBoZWFkLmlubmVySFRNTCA9ICc8c3BhbiBjbGFzcz0ibWctdGFnIj7lkIjlubY8L3NwYW4+PHNw
YW4+JyArIGl0ZW1zLmxlbmd0aCArICcg5p2hIMK3IOeCueWHu+WNleadoeeymOi0tDwvc3Bhbj4n
OwogICAgICAgIGVsLmFwcGVuZENoaWxkKGhlYWQpOwoKICAgICAgICBpdGVtcy5mb3JFYWNoKGMg
PT4gewogICAgICAgICAgICBjb25zdCByb3cgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYn
KTsKICAgICAgICAgICAgcm93LmNsYXNzTmFtZSA9ICdtZy1yb3cnCiAgICAgICAgICAgICAgICAr
ICgrc2VsZWN0ZWRJZCA9PT0gK2MuaWQgPyAnIHNlbCcgOiAnJykKICAgICAgICAgICAgICAgICsg
KG11bHRpSWRzLmluY2x1ZGVzKCtjLmlkKSA/ICcgbXVsdGknIDogJycpOwogICAgICAgICAgICBy
b3cuZGF0YXNldC5pZCA9IGMuaWQ7CgogICAgICAgICAgICBjb25zdCB0b3AgPSBkb2N1bWVudC5j
cmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgdG9wLmNsYXNzTmFtZSA9ICdtZy1yb3ct
dG9wJzsKICAgICAgICAgICAgY29uc3QgbWFpbiA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2Rp
dicpOwogICAgICAgICAgICBtYWluLmNsYXNzTmFtZSA9ICdtZy1yb3ctbWFpbic7CgogICAgICAg
ICAgICBjb25zdCB0aXRsZSA9IFN0cmluZyhjLmZhdlRpdGxlIHx8ICcnKS50cmltKCk7CiAgICAg
ICAgICAgIGlmICh0aXRsZSkgewogICAgICAgICAgICAgICAgY29uc3QgdCA9IGRvY3VtZW50LmNy
ZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICAgICAgdC5jbGFzc05hbWUgPSAnbWctdGl0
bGUnOwogICAgICAgICAgICAgICAgc2V0SGxUZXh0KHQsIHRpdGxlKTsKICAgICAgICAgICAgICAg
IG1haW4uYXBwZW5kQ2hpbGQodCk7CiAgICAgICAgICAgIH0KICAgICAgICAgICAgY29uc3QgYm9k
eSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBib2R5LmNsYXNz
TmFtZSA9ICdtZy1ib2R5JyArIChub3JtVHlwZShjLnR5cGUpID09PSAnaW1hZ2UnID8gJyBpbWcn
IDogJycpOwogICAgICAgICAgICBzZXRIbFRleHQoYm9keSwgY2xpcENvbnRlbnRQcmV2aWV3KGMp
KTsKICAgICAgICAgICAgbWFpbi5hcHBlbmRDaGlsZChib2R5KTsKICAgICAgICAgICAgdG9wLmFw
cGVuZENoaWxkKG1haW4pOwoKICAgICAgICAgICAgY29uc3Qgc3JjSWNvID0gU3RyaW5nKGMuc3Jj
SWNvbiB8fCAnJyk7CiAgICAgICAgICAgIGNvbnN0IHNyY0V4ZSA9IFN0cmluZyhjLnNyY0V4ZSB8
fCAnJyk7CiAgICAgICAgICAgIGNvbnN0IHNyY1RpdGxlID0gU3RyaW5nKGMuc3JjVGl0bGUgfHwg
JycpOwogICAgICAgICAgICBpZiAoc3JjSWNvKSB7CiAgICAgICAgICAgICAgICBjb25zdCBpbWcg
PSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdpbWcnKTsKICAgICAgICAgICAgICAgIGltZy5jbGFz
c05hbWUgPSAnbWctc3JjJzsKICAgICAgICAgICAgICAgIGltZy5zcmMgPSBTVE9SRV9CQVNFICsg
ZW5jb2RlVVJJQ29tcG9uZW50KHNyY0ljbyk7CiAgICAgICAgICAgICAgICBpbWcuYWx0ID0gJyc7
CiAgICAgICAgICAgICAgICBjb25zdCB0aXBUeHQgPSBzcmNUaXRsZSB8fCBzcmNFeGUgfHwgJ+ad
pea6kCc7CiAgICAgICAgICAgICAgICBpbWcudGl0bGUgPSB0aXBUeHQ7CiAgICAgICAgICAgICAg
ICBpbWcub25jbGljayA9IGUgPT4geyBlLnByZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0
aW9uKCk7IHNob3dTcmNUaXAoaW1nLCB0aXBUeHQpOyB9OwogICAgICAgICAgICAgICAgdG9wLmFw
cGVuZENoaWxkKGltZyk7CiAgICAgICAgICAgIH0KICAgICAgICAgICAgcm93LmFwcGVuZENoaWxk
KHRvcCk7CgogICAgICAgICAgICByb3cub25wb2ludGVyZG93biA9IGUgPT4gewogICAgICAgICAg
ICAgICAgaWYgKGUuYnV0dG9uICE9PSAwKSByZXR1cm47CiAgICAgICAgICAgICAgICBlLnN0b3BQ
cm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAgYmVnaW5QYXN0ZUZyb21JdGVtKGUsIGMpOwog
ICAgICAgICAgICB9OwogICAgICAgICAgICByb3cub25jb250ZXh0bWVudSA9IGUgPT4gewogICAg
ICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICAgICAgZS5zdG9wUHJv
cGFnYXRpb24oKTsKICAgICAgICAgICAgICAgIHNlbGVjdGVkSWQgPSBjLmlkOwogICAgICAgICAg
ICAgICAgc2hvd0N0eChlLmNsaWVudFgsIGUuY2xpZW50WSwgYyk7CiAgICAgICAgICAgIH07CiAg
ICAgICAgICAgIGVsLmFwcGVuZENoaWxkKHJvdyk7CiAgICAgICAgfSk7CgogICAgICAgIGVsLm9u
Y29udGV4dG1lbnUgPSBlID0+IHsKICAgICAgICAgICAgaWYgKGUudGFyZ2V0LmNsb3Nlc3QoJy5t
Zy1yb3cnKSkgcmV0dXJuOwogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAg
ICAgIHNlbGVjdGVkSWQgPSBpdGVtc1swXS5pZDsKICAgICAgICAgICAgc2hvd0N0eChlLmNsaWVu
dFgsIGUuY2xpZW50WSwgaXRlbXNbMF0pOwogICAgICAgIH07CiAgICAgICAgcmV0dXJuIGVsOwog
ICAgfQoKICAgIGZ1bmN0aW9uIG1ha2VJdGVtKGMsIGlkeCkgewogICAgICAgIGNvbnN0IHR5cGUg
ICA9IG5vcm1UeXBlKGMudHlwZSk7CiAgICAgICAgY29uc3QgcGlubmVkID0gaXNQaW5uZWQoYyk7
CiAgICAgICAgY29uc3QgcGFzdGVkID0gaXNQYXN0ZWQoYyk7CiAgICAgICAgY29uc3QgZWwgICAg
ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgZWwuY2xhc3NOYW1lICA9
ICdpdG0nCiAgICAgICAgICAgICsgKHNlbGVjdGVkSWQgPT0gYy5pZCA/ICcgc2VsJyA6ICcnKQog
ICAgICAgICAgICArIChtdWx0aUlkcy5pbmNsdWRlcygrYy5pZCkgPyAnIG11bHRpJyA6ICcnKTsK
ICAgICAgICBlbC5kYXRhc2V0LmlkID0gYy5pZDsKCiAgICAgICAgY29uc3QgaWNvICA9IGRvY3Vt
ZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgIGNvbnN0IGJvZHkgPSBkb2N1bWVudC5j
cmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICBib2R5LmNsYXNzTmFtZSA9ICdpLWJvZHknOwoK
ICAgICAgICBpZiAodHlwZSA9PT0gJ2ltYWdlJykgewogICAgICAgICAgICBpY28uY2xhc3NOYW1l
ID0gJ2ktaWNvIGltYWdlJzsKICAgICAgICAgICAgaWNvLmlubmVySFRNTCA9IFNWRy5pbWFnZTsK
ICAgICAgICAgICAgYmluZEltZ0hvdmVyUHJldmlldyhpY28sIGMuaWQsIGMuaW1nRmlsZSk7CiAg
ICAgICAgICAgIGNvbnN0IHdyYXAgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAg
ICAgICAgICAgd3JhcC5jbGFzc05hbWUgPSAnaS10aHVtYi13cmFwJzsKICAgICAgICAgICAgY29u
c3QgaW1nICA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2ltZycpOwogICAgICAgICAgICBpbWcu
Y2xhc3NOYW1lID0gJ2ktdGh1bWInOwogICAgICAgICAgICBpbWcuYWx0ID0gJyc7CiAgICAgICAg
ICAgIGNvbnN0IGZpbGUgPSBTdHJpbmcoYy5pbWdGaWxlIHx8ICcnKTsKICAgICAgICAgICAgbGV0
IGZhbGxiYWNrID0gU3RyaW5nKGMuZGF0YSB8fCAnJyk7CiAgICAgICAgICAgIC8vIE5ldmVyIHN5
bmMtY2FsbCBBSEsgdGh1bWIgaGVyZSDigJQgZnJlZXplcyB0YWIgc3dpdGNoZXM7IFB1c2hTdG9y
ZVRodW1icyBmaWxscyBhc3luYwogICAgICAgICAgICBpZiAoIWZhbGxiYWNrLnN0YXJ0c1dpdGgo
J2RhdGE6JykgJiYgdGh1bWJDYWNoZS5oYXMoU3RyaW5nKGMuaWQpKSkKICAgICAgICAgICAgICAg
IGZhbGxiYWNrID0gU3RyaW5nKHRodW1iQ2FjaGUuZ2V0KFN0cmluZyhjLmlkKSkpOwogICAgICAg
ICAgICBpbWcub25sb2FkID0gKCkgPT4gewogICAgICAgICAgICAgICAgY29uc3QgbXcgPSB3cmFw
LmNsaWVudFdpZHRoIHx8IDMwMDsKICAgICAgICAgICAgICAgIGNvbnN0IG53ID0gaW1nLm5hdHVy
YWxXaWR0aCAgfHwgMDsKICAgICAgICAgICAgICAgIGNvbnN0IG5oID0gaW1nLm5hdHVyYWxIZWln
aHQgfHwgMDsKICAgICAgICAgICAgICAgIGlmICghbncgfHwgIW5oKSByZXR1cm47CiAgICAgICAg
ICAgICAgICBjb25zdCBzY2FsZSA9IE1hdGgubWluKDEsIDE4MCAvIG5oLCBtdyAvIG53KTsKICAg
ICAgICAgICAgICAgIGltZy5zdHlsZS53aWR0aCAgPSBNYXRoLnJvdW5kKG53ICogc2NhbGUpICsg
J3B4JzsKICAgICAgICAgICAgICAgIGltZy5zdHlsZS5oZWlnaHQgPSBNYXRoLnJvdW5kKG5oICog
c2NhbGUpICsgJ3B4JzsKICAgICAgICAgICAgfTsKICAgICAgICAgICAgYmluZFN0b3JlVGh1bWIo
aW1nLCBmaWxlLCBjLmlkLCBmYWxsYmFjayk7CiAgICAgICAgICAgIHdyYXAuYXBwZW5kQ2hpbGQo
aW1nKTsKICAgICAgICAgICAgY29uc3QgbWV0YSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2Rp
dicpOwogICAgICAgICAgICBtZXRhLmNsYXNzTmFtZSA9ICdpLW1ldGEnOwogICAgICAgICAgICBt
ZXRhLmlubmVySFRNTCAgPSBgPHNwYW4gY2xhc3M9ImktdGltZSI+JHthZ28oYy50aW1lKX08L3Nw
YW4+JHttZXRhQ2VudGVySHRtbChmYWxzZSl9PGRpdiBjbGFzcz0iaS1tZXRhLXJpZ2h0Ij4ke2Mu
d2lkdGggPyBgPHNwYW4gY2xhc3M9ImktdGFnIj4ke2Mud2lkdGh9w5cke2MuaGVpZ2h0fSBweDwv
c3Bhbj5gIDogJyd9PC9kaXY+YDsKICAgICAgICAgICAgYm9keS5hcHBlbmRDaGlsZCh3cmFwKTsK
ICAgICAgICAgICAgYm9keS5hcHBlbmRDaGlsZChtZXRhKTsKICAgICAgICB9IGVsc2UgaWYgKHR5
cGUgPT09ICdmaWxlJykgewogICAgICAgICAgICBjb25zdCBmaWxlcyA9IFN0cmluZyhjLnByZXZp
ZXcgfHwgYy5kYXRhIHx8ICcnKS5zcGxpdCgvXHI/XG4vKS5maWx0ZXIoQm9vbGVhbik7CiAgICAg
ICAgICAgIGNvbnN0IGltYWdlUGF0aHMgPSBmaWxlcy5maWx0ZXIoZiA9PiBpc0ltYWdlRXh0KGZp
bGVFeHQoZikpKTsKICAgICAgICAgICAgY29uc3QgaWMgICAgPSBpY29uRm9yRmlsZXMoZmlsZXMp
OwogICAgICAgICAgICBpY28uY2xhc3NOYW1lID0gJ2ktaWNvICcgKyBpYy5jbHM7CiAgICAgICAg
ICAgIGljby5pbm5lckhUTUwgPSBpYy5zdmc7CgogICAgICAgICAgICBsZXQgdGh1bWJGaWxlID0g
U3RyaW5nKGMuaW1nRmlsZSB8fCAnJyk7CiAgICAgICAgICAgIC8qIGVuc3VyZUZpbGVJbWcgZGVm
ZXJyZWQ6IGF2b2lkIHN5bmMgZnJlZXplIG9uIGZpbGUgdGFiICovCgogICAgICAgICAgICAvLyBJ
bWFnZS1mb3JtYXQgZmlsZXM6IHNhbWUgdGh1bWJuYWlsIHJ1bGVzIGFzIHNjcmVlbnNob3QgY2xp
cHMKICAgICAgICAgICAgaWYgKHRodW1iRmlsZSB8fCBpbWFnZVBhdGhzLmxlbmd0aCkgewogICAg
ICAgICAgICAgICAgY29uc3Qgd3JhcCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwog
ICAgICAgICAgICAgICAgd3JhcC5jbGFzc05hbWUgPSAnaS10aHVtYi13cmFwJzsKICAgICAgICAg
ICAgICAgIGNvbnN0IGltZyAgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdpbWcnKTsKICAgICAg
ICAgICAgICAgIGltZy5jbGFzc05hbWUgPSAnaS10aHVtYic7CiAgICAgICAgICAgICAgICBpbWcu
YWx0ID0gJyc7CiAgICAgICAgICAgICAgICBpbWcub25sb2FkID0gKCkgPT4gewogICAgICAgICAg
ICAgICAgICAgIGNvbnN0IG13ID0gd3JhcC5jbGllbnRXaWR0aCB8fCAzMDA7CiAgICAgICAgICAg
ICAgICAgICAgY29uc3QgbncgPSBpbWcubmF0dXJhbFdpZHRoICB8fCAwOwogICAgICAgICAgICAg
ICAgICAgIGNvbnN0IG5oID0gaW1nLm5hdHVyYWxIZWlnaHQgfHwgMDsKICAgICAgICAgICAgICAg
ICAgICBpZiAoIW53IHx8ICFuaCkgcmV0dXJuOwogICAgICAgICAgICAgICAgICAgIGNvbnN0IHNj
YWxlID0gTWF0aC5taW4oMSwgMTgwIC8gbmgsIG13IC8gbncpOwogICAgICAgICAgICAgICAgICAg
IGltZy5zdHlsZS53aWR0aCAgPSBNYXRoLnJvdW5kKG53ICogc2NhbGUpICsgJ3B4JzsKICAgICAg
ICAgICAgICAgICAgICBpbWcuc3R5bGUuaGVpZ2h0ID0gTWF0aC5yb3VuZChuaCAqIHNjYWxlKSAr
ICdweCc7CiAgICAgICAgICAgICAgICB9OwogICAgICAgICAgICAvKiBlbnN1cmVGaWxlSW1nIGRl
ZmVycmVkOiBhdm9pZCBzeW5jIGZyZWV6ZSBvbiBmaWxlIHRhYiAqLwogICAgICAgICAgICAgICAg
YmluZFN0b3JlVGh1bWIoaW1nLCB0aHVtYkZpbGUsIGMuaWQsICcnKTsKICAgICAgICAgICAgICAg
IHdyYXAuYXBwZW5kQ2hpbGQoaW1nKTsKICAgICAgICAgICAgICAgIGJvZHkuYXBwZW5kQ2hpbGQo
d3JhcCk7CiAgICAgICAgICAgIH0KCiAgICAgICAgICAgIGNvbnN0IG5hbWUgPSBkb2N1bWVudC5j
cmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgbmFtZS5jbGFzc05hbWUgID0gJ2ktbmFt
ZSc7CiAgICAgICAgICAgIHNldEhsVGV4dChuYW1lLCBmaWxlcy5tYXAoZiA9PiBmLnNwbGl0KC9b
XFwvXS8pLnBvcCgpKS5qb2luKCdcbicpIHx8ICco5paH5Lu2KScpOwoKICAgICAgICAgICAgLy8g
U3RyaWtlIGxpc3QgZW50cnkgb25seSB3aGVuIGV2ZXJ5IHBhdGggaXMgZ29uZSAobXVsdGktZmls
ZTogYWxsIG1pc3NpbmcpCiAgICAgICAgICAgIGNvbnN0IHBhdGhSb3dzID0gY2hlY2tGaWxlUGF0
aHMoZmlsZXMpOwogICAgICAgICAgICBjb25zdCBhbGxHb25lID0gcGF0aFJvd3MubGVuZ3RoID4g
MCAmJiBwYXRoUm93cy5ldmVyeShyID0+IHIuZXhpc3RzID09PSBmYWxzZSk7CiAgICAgICAgICAg
IGlmIChhbGxHb25lKQogICAgICAgICAgICAgICAgZWwuY2xhc3NMaXN0LmFkZCgnZ29uZScpOwoK
ICAgICAgICAgICAgY29uc3QgZGV0YWlsID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7
CiAgICAgICAgICAgIGRldGFpbC5jbGFzc05hbWUgPSAnaS1maWxlLWRldGFpbCc7CgogICAgICAg
ICAgICBjb25zdCBtZXRhID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAg
ICAgIG1ldGEuY2xhc3NOYW1lID0gJ2ktbWV0YSc7CiAgICAgICAgICAgIGxldCByaWdodCA9IGA8
c3BhbiBjbGFzcz0iaS10YWciPiR7Yy5maWxlQ291bnQgfHwgZmlsZXMubGVuZ3RoIHx8IDF9IOS4
quaWh+S7tjwvc3Bhbj5gOwogICAgICAgICAgICBpZiAoKHRodW1iRmlsZSB8fCBpbWFnZVBhdGhz
Lmxlbmd0aCkgJiYgYy53aWR0aCkKICAgICAgICAgICAgICAgIHJpZ2h0ID0gYDxzcGFuIGNsYXNz
PSJpLXRhZyI+JHtjLndpZHRofcOXJHtjLmhlaWdodH0gcHg8L3NwYW4+YCArIHJpZ2h0OwogICAg
ICAgICAgICBjb25zdCBleHBhbmRIdG1sID0KICAgICAgICAgICAgICAgIGA8c3ZnIHZpZXdCb3g9
IjAgMCAxNiAxNiIgd2lkdGg9IjEwIiBoZWlnaHQ9IjEwIiBmaWxsPSJub25lIiBzdHJva2U9ImN1
cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCI+YCAr
CiAgICAgICAgICAgICAgICBgPHBvbHlsaW5lIHBvaW50cz0iNCA2IDggMTAgMTIgNiIvPjwvc3Zn
PmA7CiAgICAgICAgICAgIGNvbnN0IGNvbGxhcHNlSHRtbCA9CiAgICAgICAgICAgICAgICBgPHN2
ZyB2aWV3Qm94PSIwIDAgMTYgMTYiIHdpZHRoPSIxMCIgaGVpZ2h0PSIxMCIgZmlsbD0ibm9uZSIg
c3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44IiBzdHJva2UtbGluZWNhcD0i
cm91bmQiPmAgKwogICAgICAgICAgICAgICAgYDxwb2x5bGluZSBwb2ludHM9IjQgMTAgOCA2IDEy
IDEwIi8+PC9zdmc+YDsKICAgICAgICAgICAgbWV0YS5pbm5lckhUTUwgPQogICAgICAgICAgICAg
ICAgYDxzcGFuIGNsYXNzPSJpLXRpbWUiPiR7YWdvKGMudGltZSl9PC9zcGFuPmAgKwogICAgICAg
ICAgICAgICAgbWV0YUNlbnRlckh0bWwoeyBvbjogdHJ1ZSwgaHRtbDogZXhwYW5kSHRtbCB9KSAr
CiAgICAgICAgICAgICAgICBgPGRpdiBjbGFzcz0iaS1tZXRhLXJpZ2h0Ij4ke3JpZ2h0fTwvZGl2
PmA7CgogICAgICAgICAgICBjb25zdCBleHBCdG4gPSBtZXRhLnF1ZXJ5U2VsZWN0b3IoJy5pLWV4
cGFuZC1idG4nKTsKICAgICAgICAgICAgbGV0IGRldGFpbEJ1aWx0ID0gZmFsc2U7CiAgICAgICAg
ICAgIGV4cEJ0bi5vbmNsaWNrID0gZSA9PiB7CiAgICAgICAgICAgICAgICBlLnByZXZlbnREZWZh
dWx0KCk7CiAgICAgICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAg
ICAgY29uc3Qgb3BlbiA9ICFkZXRhaWwuY2xhc3NMaXN0LmNvbnRhaW5zKCdvbicpOwogICAgICAg
ICAgICAgICAgaWYgKG9wZW4gJiYgIWRldGFpbEJ1aWx0KSB7CiAgICAgICAgICAgICAgICAgICAg
ZmlsbEZpbGVEZXRhaWxQYW5lbChkZXRhaWwsIHBhdGhSb3dzKTsKICAgICAgICAgICAgICAgICAg
ICBkZXRhaWxCdWlsdCA9IHRydWU7CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICBk
ZXRhaWwuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCBvcGVuKTsKICAgICAgICAgICAgICAgIGV4cEJ0
bi5pbm5lckhUTUwgPSBvcGVuID8gY29sbGFwc2VIdG1sIDogZXhwYW5kSHRtbDsKICAgICAgICAg
ICAgfTsKCiAgICAgICAgICAgIGJvZHkuYXBwZW5kQ2hpbGQobmFtZSk7CiAgICAgICAgICAgIGJv
ZHkuYXBwZW5kQ2hpbGQoZGV0YWlsKTsKICAgICAgICAgICAgYm9keS5hcHBlbmRDaGlsZChtZXRh
KTsKICAgICAgICB9IGVsc2UgewogICAgICAgICAgICBjb25zdCBpc01kID0gISEoYy5pc01kID09
PSB0cnVlIHx8IGMuaXNNZCA9PT0gMSB8fCBjLmlzTWQgPT09ICd0cnVlJyB8fCBjLmlzTWQgPT09
ICcxJykgfHwgaXNNYXJrZG93bihjLmRhdGEgfHwgYy5wcmV2aWV3IHx8ICcnKTsKICAgICAgICAg
ICAgY29uc3QgaXNSaWNoID0gISEoYy5pc1JpY2ggPT09IHRydWUgfHwgYy5pc1JpY2ggPT09IDEg
fHwgYy5pc1JpY2ggPT09ICd0cnVlJyB8fCBjLmlzUmljaCA9PT0gJzEnKTsKICAgICAgICAgICAg
Y29uc3QgdXNlTSA9IGlzTWQgfHwgaXNSaWNoOwogICAgICAgICAgICBpY28uY2xhc3NOYW1lID0g
dXNlTSA/ICdpLWljbyBtZCcgOiAnaS1pY28gdGV4dCc7CiAgICAgICAgICAgIGljby5pbm5lckhU
TUwgPSB1c2VNID8gKFNWRy5tZCB8fCBTVkcudGV4dCkgOiBTVkcudGV4dDsKICAgICAgICAgICAg
LyogcGxhaW4tbGlzdC1wcmV2ICovCiAgICAgICAgICAgIC8qIHByZXZpZXctZWxsaXBzaXMgKi8K
ICAgICAgICAgICAgbGV0IHR4dCAgPSBjLnByZXZpZXcgfHwgYy5kYXRhIHx8ICcnOwogICAgICAg
ICAgICB7IGNvbnN0IF9uID0gTnVtYmVyKGMuY2hhckNvdW50KSB8fCAwOyBpZiAoX24gPiB0eHQu
bGVuZ3RoICYmIHR4dC5sZW5ndGgpIHR4dCArPSAnLi4uJzsgfQogICAgICAgICAgICBjb25zdCBw
cmV2ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIHByZXYuY2xh
c3NOYW1lICA9ICdpLXByZXYnICsgKGlzVXJsKHR4dCkgPyAnIHVybCcgOiAnJyk7CiAgICAgICAg
ICAgIHNldEhsVGV4dChwcmV2LCB0eHQpOwoKICAgICAgICAgICAgY29uc3QgbWV0YSA9IGRvY3Vt
ZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBtZXRhLmNsYXNzTmFtZSA9ICdp
LW1ldGEnOwoKICAgICAgICAgICAgY29uc3QgY2hhcnMgPSBOdW1iZXIoYy5jaGFyQ291bnQpIHx8
IDA7CiAgICAgICAgICAgIGxldCByaWdodEhUTUwgPSAnJzsKICAgICAgICAgICAgcmlnaHRIVE1M
ICs9IGA8c3BhbiBjbGFzcz0iaS1jaGFycyI+PHNwYW4gY2xhc3M9Im4iPiR7Y2hhcnN9PC9zcGFu
PiDlrZfnrKY8L3NwYW4+YDsKCiAgICAgICAgICAgIG1ldGEuaW5uZXJIVE1MID0KICAgICAgICAg
ICAgICAgIGA8c3BhbiBjbGFzcz0iaS10aW1lIj4ke2FnbyhjLnRpbWUpfTwvc3Bhbj5gICsKICAg
ICAgICAgICAgICAgIG1ldGFDZW50ZXJIdG1sKHsKICAgICAgICAgICAgICAgICAgICBvbjogZmFs
c2UsCiAgICAgICAgICAgICAgICAgICAgaHRtbDogYDxzdmcgdmlld0JveD0iMCAwIDE2IDE2IiB3
aWR0aD0iMTAiIGhlaWdodD0iMTAiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBz
dHJva2Utd2lkdGg9IjEuOCIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIj48cG9seWxpbmUgcG9pbnRz
PSI0IDYgOCAxMCAxMiA2Ii8+PC9zdmc+YAogICAgICAgICAgICAgICAgfSkgKwogICAgICAgICAg
ICAgICAgYDxkaXYgY2xhc3M9ImktbWV0YS1yaWdodCB0ZXh0LW1ldGEiPiR7cmlnaHRIVE1MfTwv
ZGl2PmA7CgogICAgICAgICAgICBib2R5LmFwcGVuZENoaWxkKHByZXYpOwogICAgICAgICAgICBi
b2R5LmFwcGVuZENoaWxkKG1ldGEpOwoKICAgICAgICAgICAgY29uc3QgZXhwQnRuID0gbWV0YS5x
dWVyeVNlbGVjdG9yKCcuaS1leHBhbmQtYnRuJyk7CiAgICAgICAgICAgIGlmIChleHBCdG4pIHsK
ICAgICAgICAgICAgICAgIGV4cEJ0bi5vbmNsaWNrID0gZSA9PiB7CiAgICAgICAgICAgICAgICAg
ICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgICAgICBjb25zdCBleHBhbmRl
ZCA9IHByZXYuY2xhc3NMaXN0LnRvZ2dsZSgnZXhwYW5kZWQnKTsKICAgICAgICAgICAgICAgICAg
ICBleHBCdG4uaW5uZXJIVE1MID0gZXhwYW5kZWQKICAgICAgICAgICAgICAgICAgICAgICAgPyBg
PHN2ZyB2aWV3Qm94PSIwIDAgMTYgMTYiIHdpZHRoPSIxMCIgaGVpZ2h0PSIxMCIgZmlsbD0ibm9u
ZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44IiBzdHJva2UtbGluZWNh
cD0icm91bmQiPjxwb2x5bGluZSBwb2ludHM9IjQgMTAgOCA2IDEyIDEwIi8+PC9zdmc+YAogICAg
ICAgICAgICAgICAgICAgICAgICA6IGA8c3ZnIHZpZXdCb3g9IjAgMCAxNiAxNiIgd2lkdGg9IjEw
IiBoZWlnaHQ9IjEwIiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdp
ZHRoPSIxLjgiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCI+PHBvbHlsaW5lIHBvaW50cz0iNCA2IDgg
MTAgMTIgNiIvPjwvc3ZnPmA7CiAgICAgICAgICAgICAgICB9OwogICAgICAgICAgICAgICAgY29u
c3QgY2hlY2tPdmVyZmxvdyA9ICgpID0+IHsKICAgICAgICAgICAgICAgICAgICBjb25zdCBwbGFp
bkxlbiA9IFN0cmluZyhjLnByZXZpZXcgfHwgYy5kYXRhIHx8ICcnKS5sZW5ndGg7CiAgICAgICAg
ICAgICAgICAgICAgY29uc3QgZnVsbE4gPSBOdW1iZXIoYy5jaGFyQ291bnQpIHx8IDA7CiAgICAg
ICAgICAgICAgICAgICAgY29uc3QgdHJ1bmMgPSBmdWxsTiA+IHBsYWluTGVuOwogICAgICAgICAg
ICAgICAgICAgIGlmIChwcmV2LnNjcm9sbEhlaWdodCA+IHByZXYuY2xpZW50SGVpZ2h0ICsgMiB8
fCB0cnVuYykKICAgICAgICAgICAgICAgICAgICAgICAgZXhwQnRuLmNsYXNzTGlzdC5hZGQoJ29u
Jyk7CiAgICAgICAgICAgICAgICAgICAgZWxzZQogICAgICAgICAgICAgICAgICAgICAgICBleHBC
dG4uY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICAgICAgICAgIH07CiAgICAgICAgICAg
ICAgICByZXF1ZXN0QW5pbWF0aW9uRnJhbWUoY2hlY2tPdmVyZmxvdyk7CiAgICAgICAgICAgICAg
ICBzZXRUaW1lb3V0KGNoZWNrT3ZlcmZsb3csIDgwKTsKICAgICAgICAgICAgfQogICAgICAgIH0K
CiAgICAgICAgY29uc3QgZmF2VCA9IFN0cmluZyhjLmZhdlRpdGxlIHx8ICcnKS50cmltKCk7CiAg
ICAgICAgaWYgKGZhdlQpIHsKICAgICAgICAgICAgY29uc3QgZnQgPSBkb2N1bWVudC5jcmVhdGVF
bGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgZnQuY2xhc3NOYW1lID0gJ2ktZmF2LXRpdGxlJzsK
ICAgICAgICAgICAgc2V0SGxUZXh0KGZ0LCBmYXZUKTsKICAgICAgICAgICAgYm9keS5pbnNlcnRC
ZWZvcmUoZnQsIGJvZHkuZmlyc3RDaGlsZCk7CiAgICAgICAgfQoKICAgICAgICBpZiAocGFzdGVk
KSB7CiAgICAgICAgICAgIGNvbnN0IGJhZGdlID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnc3Bh
bicpOwogICAgICAgICAgICBiYWRnZS5jbGFzc05hbWUgPSAnaS11c2VkJzsKICAgICAgICAgICAg
YmFkZ2UudGl0bGUgPSAn5bey57KY6LS0JzsKICAgICAgICAgICAgYmFkZ2UuaW5uZXJIVE1MID0g
YDxzdmcgdmlld0JveD0iMCAwIDE2IDE2IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xv
ciIgc3Ryb2tlLXdpZHRoPSIyLjQiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVq
b2luPSJyb3VuZCI+PHBvbHlsaW5lIHBvaW50cz0iMy41IDguNSA2LjUgMTEuNSAxMi41IDQuNSIv
Pjwvc3ZnPmA7CiAgICAgICAgICAgIGljby5hcHBlbmRDaGlsZChiYWRnZSk7CiAgICAgICAgfQoK
ICAgICAgICBjb25zdCBudW0gPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAg
ICBudW0uY2xhc3NOYW1lID0gJ2ktbnVtJzsKICAgICAgICBjb25zdCBudW1UeHQgPSBkb2N1bWVu
dC5jcmVhdGVFbGVtZW50KCdzcGFuJyk7CiAgICAgICAgbnVtVHh0LnRleHRDb250ZW50ID0gaWR4
OwogICAgICAgIG51bS5hcHBlbmRDaGlsZChudW1UeHQpOwogICAgICAgIGNvbnN0IHNyY0ljbyA9
IFN0cmluZyhjLnNyY0ljb24gfHwgJycpOwogICAgICAgIGNvbnN0IHNyY0V4ZSA9IFN0cmluZyhj
LnNyY0V4ZSB8fCAnJyk7CiAgICAgICAgY29uc3Qgc3JjVGl0bGUgPSBTdHJpbmcoYy5zcmNUaXRs
ZSB8fCAnJyk7CiAgICAgICAgaWYgKHNyY0ljbykgewogICAgICAgICAgICBjb25zdCBpbWcgPSBk
b2N1bWVudC5jcmVhdGVFbGVtZW50KCdpbWcnKTsKICAgICAgICAgICAgaW1nLmNsYXNzTmFtZSA9
ICdpLXNyYy1pY28nOwogICAgICAgICAgICBpbWcuc3JjID0gU1RPUkVfQkFTRSArIGVuY29kZVVS
SUNvbXBvbmVudChzcmNJY28pOwogICAgICAgICAgICBpbWcuYWx0ID0gJyc7CiAgICAgICAgICAg
IGNvbnN0IHRpcFR4dCA9IHNyY1RpdGxlIHx8IHNyY0V4ZSB8fCAn5p2l5rqQJzsKICAgICAgICAg
ICAgaW1nLnRpdGxlID0gdGlwVHh0OwogICAgICAgICAgICBpbWcub25jbGljayA9IGUgPT4geyBl
LnByZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0aW9uKCk7IHNob3dTcmNUaXAoaW1nLCB0
aXBUeHQpOyB9OwogICAgICAgICAgICBudW0uYXBwZW5kQ2hpbGQoaW1nKTsKICAgICAgICB9Cgog
ICAgICAgIGVsLmFwcGVuZENoaWxkKGljbyk7CiAgICAgICAgZWwuYXBwZW5kQ2hpbGQoYm9keSk7
CiAgICAgICAgZWwuYXBwZW5kQ2hpbGQobnVtKTsKCiAgICAgICAgZWwub25wb2ludGVyZG93biA9
IGUgPT4gewogICAgICAgICAgICBiZWdpblBhc3RlRnJvbUl0ZW0oZSwgYyk7CiAgICAgICAgfTsK
ICAgICAgICBlbC5vbmNvbnRleHRtZW51ID0gZSA9PiB7CiAgICAgICAgICAgIGUucHJldmVudERl
ZmF1bHQoKTsKICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IGMuaWQ7CiAgICAgICAgICAgIHNob3dD
dHgoZS5jbGllbnRYLCBlLmNsaWVudFksIGMpOwogICAgICAgIH07CgogICAgICAgIHJldHVybiBl
bDsKICAgIH0KCiAgICBjb25zdCBwYXRoVGlwRWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgn
cGF0aC10aXAnKTsKICAgIGxldCBwYXRoVGlwVGltZXIgPSAwOwogICAgbGV0IHBhdGhUaXBIaWRl
VGltZXIgPSAwOwogICAgbGV0IHBhdGhUaXBUb2tlbiA9IDA7CiAgICBsZXQgcGF0aFRpcEFuY2hv
ckJ0biA9IG51bGw7CgogICAgZnVuY3Rpb24gaGlkZVBhdGhUaXAoKSB7CiAgICAgICAgY2xlYXJU
aW1lb3V0KHBhdGhUaXBUaW1lcik7CiAgICAgICAgY2xlYXJUaW1lb3V0KHBhdGhUaXBIaWRlVGlt
ZXIpOwogICAgICAgIHBhdGhUaXBUb2tlbisrOwogICAgICAgIGlmIChwYXRoVGlwQW5jaG9yQnRu
KSB7CiAgICAgICAgICAgIHBhdGhUaXBBbmNob3JCdG4uY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsK
ICAgICAgICAgICAgcGF0aFRpcEFuY2hvckJ0biA9IG51bGw7CiAgICAgICAgfQogICAgICAgIGlm
IChwYXRoVGlwRWwpIHsKICAgICAgICAgICAgcGF0aFRpcEVsLmNsYXNzTGlzdC5yZW1vdmUoJ29u
Jyk7CiAgICAgICAgICAgIHBhdGhUaXBFbC5zZXRBdHRyaWJ1dGUoJ2FyaWEtaGlkZGVuJywgJ3Ry
dWUnKTsKICAgICAgICB9CiAgICB9CiAgICBmdW5jdGlvbiBwbGFjZVBhdGhUaXAoYW5jaG9yRWwp
IHsKICAgICAgICBpZiAoIXBhdGhUaXBFbCB8fCAhYW5jaG9yRWwpIHJldHVybjsKICAgICAgICBj
b25zdCB0aXAgPSBwYXRoVGlwRWw7CiAgICAgICAgY29uc3QgYXIgPSBhbmNob3JFbC5nZXRCb3Vu
ZGluZ0NsaWVudFJlY3QoKTsKICAgICAgICBjb25zdCBwYWQgPSA4OwogICAgICAgIHRpcC5zdHls
ZS5sZWZ0ID0gJzBweCc7CiAgICAgICAgdGlwLnN0eWxlLnRvcCA9ICcwcHgnOwogICAgICAgIHRp
cC5jbGFzc0xpc3QuYWRkKCdvbicpOwogICAgICAgIGNvbnN0IHR3ID0gdGlwLm9mZnNldFdpZHRo
OwogICAgICAgIGNvbnN0IHRoID0gdGlwLm9mZnNldEhlaWdodDsKICAgICAgICBsZXQgbGVmdCA9
IGFyLmxlZnQ7CiAgICAgICAgbGV0IHRvcCA9IGFyLmJvdHRvbSArIDY7CiAgICAgICAgaWYgKGxl
ZnQgKyB0dyA+IHdpbmRvdy5pbm5lcldpZHRoIC0gcGFkKQogICAgICAgICAgICBsZWZ0ID0gTWF0
aC5tYXgocGFkLCB3aW5kb3cuaW5uZXJXaWR0aCAtIHR3IC0gcGFkKTsKICAgICAgICBpZiAobGVm
dCA8IHBhZCkgbGVmdCA9IHBhZDsKICAgICAgICBpZiAodG9wICsgdGggPiB3aW5kb3cuaW5uZXJI
ZWlnaHQgLSBwYWQpCiAgICAgICAgICAgIHRvcCA9IE1hdGgubWF4KHBhZCwgYXIudG9wIC0gdGgg
LSA2KTsKICAgICAgICB0aXAuc3R5bGUubGVmdCA9IGxlZnQgKyAncHgnOwogICAgICAgIHRpcC5z
dHlsZS50b3AgPSB0b3AgKyAncHgnOwogICAgfQogICAgICAgIGZ1bmN0aW9uIGNoZWNrRmlsZVBh
dGhzKHBhdGhzKSB7CiAgICAgICAgY29uc3QgbGlzdCA9IChwYXRocyB8fCBbXSkubWFwKHAgPT4g
ewogICAgICAgICAgICBsZXQgcGF0aCA9IFN0cmluZyhwIHx8ICcnKS50cmltKCk7CiAgICAgICAg
ICAgIGlmICgocGF0aC5zdGFydHNXaXRoKCciJykgJiYgcGF0aC5lbmRzV2l0aCgnIicpKSB8fCAo
cGF0aC5zdGFydHNXaXRoKCInIikgJiYgcGF0aC5lbmRzV2l0aCgiJyIpKSkKICAgICAgICAgICAg
ICAgIHBhdGggPSBwYXRoLnNsaWNlKDEsIC0xKS50cmltKCk7CiAgICAgICAgICAgIHJldHVybiBw
YXRoOwogICAgICAgIH0pOwogICAgICAgIC8vIE9uZSBob3N0IHJvdW5kLXRyaXAgZm9yIHRoZSB3
aG9sZSBsaXN0IOKAlCBOw5cgcGF0aEV4aXN0cyBmcmVlemVzIGZpbGUgdGFiCiAgICAgICAgdHJ5
IHsKICAgICAgICAgICAgY29uc3QgcmF3ID0gYWhrUmV0KCdjaGVja1BhdGhzJywgbGlzdC5qb2lu
KCdcbicpKTsKICAgICAgICAgICAgaWYgKHJhdykgewogICAgICAgICAgICAgICAgY29uc3QgcGFy
c2VkID0gdHlwZW9mIHJhdyA9PT0gJ3N0cmluZycgPyBKU09OLnBhcnNlKHJhdykgOiByYXc7CiAg
ICAgICAgICAgICAgICBpZiAoQXJyYXkuaXNBcnJheShwYXJzZWQpICYmIHBhcnNlZC5sZW5ndGgp
IHsKICAgICAgICAgICAgICAgICAgICByZXR1cm4gbGlzdC5tYXAoKHBhdGgsIGkpID0+IHsKICAg
ICAgICAgICAgICAgICAgICAgICAgY29uc3Qgcm93ID0gcGFyc2VkW2ldIHx8IHt9OwogICAgICAg
ICAgICAgICAgICAgICAgICByZXR1cm4gewogICAgICAgICAgICAgICAgICAgICAgICAgICAgcGF0
aDogcGF0aCB8fCBTdHJpbmcocm93LnBhdGggfHwgJycpLAogICAgICAgICAgICAgICAgICAgICAg
ICAgICAgZXhpc3RzOiByb3cuZXhpc3RzID09PSB0cnVlIHx8IHJvdy5leGlzdHMgPT09IDEgfHwg
cm93LmV4aXN0cyA9PT0gJzEnLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgaXNEaXI6ICEh
KHJvdy5pc0RpciA9PT0gdHJ1ZSB8fCByb3cuaXNEaXIgPT09IDEgfHwgcm93LmlzRGlyID09PSAn
MScpCiAgICAgICAgICAgICAgICAgICAgICAgIH07CiAgICAgICAgICAgICAgICAgICAgfSk7CiAg
ICAgICAgICAgICAgICB9CiAgICAgICAgICAgIH0KICAgICAgICB9IGNhdGNoIHt9CiAgICAgICAg
cmV0dXJuIGxpc3QubWFwKHBhdGggPT4gewogICAgICAgICAgICBpZiAoIXBhdGgpIHJldHVybiB7
IHBhdGgsIGV4aXN0czogZmFsc2UsIGlzRGlyOiBmYWxzZSB9OwogICAgICAgICAgICBsZXQgZXhp
c3RzID0gZmFsc2U7CiAgICAgICAgICAgIHRyeSB7CiAgICAgICAgICAgICAgICBjb25zdCBmbGFn
ID0gU3RyaW5nKGFoa1JldCgncGF0aEV4aXN0cycsIHBhdGgpID8/ICcnKS50cmltKCkudG9Mb3dl
ckNhc2UoKTsKICAgICAgICAgICAgICAgIGV4aXN0cyA9IChmbGFnID09PSAnMScgfHwgZmxhZyA9
PT0gJ3RydWUnKTsKICAgICAgICAgICAgfSBjYXRjaCB7fQogICAgICAgICAgICByZXR1cm4geyBw
YXRoLCBleGlzdHMsIGlzRGlyOiBmYWxzZSB9OwogICAgICAgIH0pOwogICAgfQogICAgZnVuY3Rp
b24gZmlsbEZpbGVEZXRhaWxQYW5lbChjb250YWluZXIsIHJvd3MpIHsKICAgICAgICBjb250YWlu
ZXIuaW5uZXJIVE1MID0gJyc7CiAgICAgICAgaWYgKCFyb3dzLmxlbmd0aCkgewogICAgICAgICAg
ICBjb25zdCBlbXB0eSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAg
ICBlbXB0eS5jbGFzc05hbWUgPSAnZmQtcGF0aCc7CiAgICAgICAgICAgIGVtcHR5LnRleHRDb250
ZW50ID0gJ+aXoOi3r+W+hCc7CiAgICAgICAgICAgIGNvbnRhaW5lci5hcHBlbmRDaGlsZChlbXB0
eSk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgcm93cy5mb3JFYWNoKHIg
PT4gewogICAgICAgICAgICBjb25zdCBwYXRoID0gU3RyaW5nKHIucGF0aCB8fCAnJyk7CiAgICAg
ICAgICAgIGNvbnN0IG1pc3NpbmcgPSByLmV4aXN0cyA9PT0gZmFsc2U7CiAgICAgICAgICAgIGNv
bnN0IGJsb2NrID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIGJs
b2NrLmNsYXNzTmFtZSA9ICdmZC1ibG9jayc7CgogICAgICAgICAgICBjb25zdCBwYXRoRWwgPSBk
b2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgcGF0aEVsLmNsYXNzTmFt
ZSA9ICdmZC1wYXRoJyArIChtaXNzaW5nID8gJyBkZWFkJyA6ICcgbGl2ZScpOwogICAgICAgICAg
ICBwYXRoRWwudGV4dENvbnRlbnQgPSBwYXRoIHx8ICco56m66Lev5b6EKSc7CiAgICAgICAgICAg
IGlmICghbWlzc2luZykgewogICAgICAgICAgICAgICAgcGF0aEVsLm9uY2xpY2sgPSBlID0+IHsK
ICAgICAgICAgICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgICAgICAg
ICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgICAgICBhaGsoJ29wZW5QYXRo
JywgcGF0aCk7CiAgICAgICAgICAgICAgICB9OwogICAgICAgICAgICB9CiAgICAgICAgICAgIGJs
b2NrLmFwcGVuZENoaWxkKHBhdGhFbCk7CgogICAgICAgICAgICBjb25zdCBhY3Rpb25zID0gZG9j
dW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIGFjdGlvbnMuY2xhc3NOYW1l
ID0gJ2ZkLWFjdGlvbnMnOwoKICAgICAgICAgICAgY29uc3QgY29weUJ0biA9IGRvY3VtZW50LmNy
ZWF0ZUVsZW1lbnQoJ2J1dHRvbicpOwogICAgICAgICAgICBjb3B5QnRuLnR5cGUgPSAnYnV0dG9u
JzsKICAgICAgICAgICAgY29weUJ0bi5jbGFzc05hbWUgPSAnZmQtYnRuJzsKICAgICAgICAgICAg
Y29weUJ0bi5pbm5lckhUTUwgPSAnPHNwYW4gY2xhc3M9ImZkLWljbyI+8J+Ulzwvc3Bhbj48c3Bh
biBjbGFzcz0iZmQtdHh0Ij7lpI3liLbot6/lvoQ8L3NwYW4+JzsKICAgICAgICAgICAgY29weUJ0
bi5vbmNsaWNrID0gZSA9PiB7CiAgICAgICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAg
ICAgICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAgYWhrKCdj
b3B5UGF0aCcsIHBhdGgpOwogICAgICAgICAgICAgICAgY29weUJ0bi5xdWVyeVNlbGVjdG9yKCcu
ZmQtdHh0JykudGV4dENvbnRlbnQgPSAn5bey5aSN5Yi2JzsKICAgICAgICAgICAgICAgIGNvcHlC
dG4uY2xhc3NMaXN0LmFkZCgnb2snKTsKICAgICAgICAgICAgICAgIHNldFRpbWVvdXQoKCkgPT4g
ewogICAgICAgICAgICAgICAgICAgIGNvcHlCdG4ucXVlcnlTZWxlY3RvcignLmZkLXR4dCcpLnRl
eHRDb250ZW50ID0gJ+WkjeWItui3r+W+hCc7CiAgICAgICAgICAgICAgICAgICAgY29weUJ0bi5j
bGFzc0xpc3QucmVtb3ZlKCdvaycpOwogICAgICAgICAgICAgICAgfSwgMTIwMCk7CiAgICAgICAg
ICAgIH07CiAgICAgICAgICAgIGFjdGlvbnMuYXBwZW5kQ2hpbGQoY29weUJ0bik7CgogICAgICAg
ICAgICBjb25zdCBmb2xkZXJCdG4gPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdidXR0b24nKTsK
ICAgICAgICAgICAgZm9sZGVyQnRuLnR5cGUgPSAnYnV0dG9uJzsKICAgICAgICAgICAgZm9sZGVy
QnRuLmNsYXNzTmFtZSA9ICdmZC1idG4nOwogICAgICAgICAgICBmb2xkZXJCdG4uaW5uZXJIVE1M
ID0gJzxzcGFuIGNsYXNzPSJmZC1pY28iPvCfk4I8L3NwYW4+PHNwYW4gY2xhc3M9ImZkLXR4dCI+
5omT5byA5omA5Zyo5paH5Lu25aS5PC9zcGFuPic7CiAgICAgICAgICAgIGZvbGRlckJ0bi5vbmNs
aWNrID0gZSA9PiB7CiAgICAgICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAg
ICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAgYWhrKCdvcGVuRm9s
ZGVyJywgcGF0aCk7CiAgICAgICAgICAgIH07CiAgICAgICAgICAgIGFjdGlvbnMuYXBwZW5kQ2hp
bGQoZm9sZGVyQnRuKTsKCiAgICAgICAgICAgIGJsb2NrLmFwcGVuZENoaWxkKGFjdGlvbnMpOwog
ICAgICAgICAgICBjb250YWluZXIuYXBwZW5kQ2hpbGQoYmxvY2spOwogICAgICAgIH0pOwogICAg
fQoKICAgIGNvbnN0IGN0eEVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2N0eCcpOwogICAg
ZnVuY3Rpb24gc2hvd0N0eCh4LCB5LCBjKSB7CiAgICAgICAgY3R4Q2xpcCA9IGM7CiAgICAgICAg
c2VsZWN0ZWRJZCA9IGMuaWQ7CiAgICAgICAgcmFuZ2VBbmNob3JJZCA9IGMuaWQ7CiAgICAgICAg
cmFuZ2VBbmNob3JDbGlja2VkID0gdHJ1ZTsKICAgICAgICBjb25zdCBjbGVhckJ0biA9IGRvY3Vt
ZW50LmdldEVsZW1lbnRCeUlkKCdjLWNsZWFyLXBhc3RlZCcpOwogICAgICAgIGlmIChjbGVhckJ0
bikgY2xlYXJCdG4uc3R5bGUuZGlzcGxheSA9IGlzUGFzdGVkKGMpID8gJycgOiAnbm9uZSc7Cgog
ICAgICAgIGNvbnN0IHBpbkJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjLXBpbicpOwog
ICAgICAgIGlmIChwaW5CdG4pIHsKICAgICAgICAgICAgY29uc3Qgb24gPSBpc1Bpbm5lZChjKTsK
ICAgICAgICAgICAgcGluQnRuLmlubmVySFRNTCA9IG9uCiAgICAgICAgICAgICAgICA/ICc8c3Bh
biBjbGFzcz0iYy1pY28iPuKYhTwvc3Bhbj7lj5bmtojmlLbol48nCiAgICAgICAgICAgICAgICA6
ICc8c3BhbiBjbGFzcz0iYy1pY28iPuKYhTwvc3Bhbj7mlLbol48nOwogICAgICAgIH0KICAgICAg
ICBjb25zdCB0aXRsZUJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjLXRpdGxlJyk7CiAg
ICAgICAgaWYgKHRpdGxlQnRuKSB7CiAgICAgICAgICAgIGNvbnN0IHNob3dUaXRsZSA9IGlzUGlu
bmVkKGMpIHx8IGN1clRhYiA9PT0gJ3Bpbm5lZCc7CiAgICAgICAgICAgIHRpdGxlQnRuLnN0eWxl
LmRpc3BsYXkgPSBzaG93VGl0bGUgPyAnJyA6ICdub25lJzsKICAgICAgICAgICAgaWYgKHNob3dU
aXRsZSkKICAgICAgICAgICAgICAgIHRpdGxlQnRuLmlubmVySFRNTCA9IChTdHJpbmcoYy5mYXZU
aXRsZSB8fCAnJykudHJpbSgpID8gJzxzcGFuIGNsYXNzPSJjLWljbyI+4pyOPC9zcGFuPue8lui+
keagh+mimCcgOiAnPHNwYW4gY2xhc3M9ImMtaWNvIj7inI48L3NwYW4+6K6+572u5qCH6aKYJyk7
CiAgICAgICAgfQogICAgICAgIGNvbnN0IG1lcmdlQnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ2MtbWVyZ2UnKTsKICAgICAgICBjb25zdCB1bm1lcmdlQnRuID0gZG9jdW1lbnQuZ2V0RWxl
bWVudEJ5SWQoJ2MtdW5tZXJnZScpOwogICAgICAgIGNvbnN0IG9uUGlubmVkID0gY3VyVGFiID09
PSAncGlubmVkJzsKICAgICAgICBpZiAobWVyZ2VCdG4pCiAgICAgICAgICAgIG1lcmdlQnRuLnN0
eWxlLmRpc3BsYXkgPSAob25QaW5uZWQgJiYgbXVsdGlJZHMubGVuZ3RoID49IDIpID8gJycgOiAn
bm9uZSc7CiAgICAgICAgaWYgKHVubWVyZ2VCdG4pCiAgICAgICAgICAgIHVubWVyZ2VCdG4uc3R5
bGUuZGlzcGxheSA9IChvblBpbm5lZCAmJiBmYXZHcm91cE9mKGMpKSA/ICcnIDogJ25vbmUnOwog
ICAgICAgIGN0eEVsLmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAgICAgICAgY3R4RWwuc3R5bGUubGVm
dCA9IHggKyAncHgnOwogICAgICAgIGN0eEVsLnN0eWxlLnRvcCAgPSB5ICsgJ3B4JzsKICAgICAg
ICByZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4gewogICAgICAgICAgICBjb25zdCByID0gY3R4
RWwuZ2V0Qm91bmRpbmdDbGllbnRSZWN0KCk7CiAgICAgICAgICAgIGlmIChyLnJpZ2h0ICA+IGlu
bmVyV2lkdGgpICBjdHhFbC5zdHlsZS5sZWZ0ID0gKHggLSByLndpZHRoKSAgKyAncHgnOwogICAg
ICAgICAgICBpZiAoci5ib3R0b20gPiBpbm5lckhlaWdodCkgY3R4RWwuc3R5bGUudG9wICA9ICh5
IC0gci5oZWlnaHQpICsgJ3B4JzsKICAgICAgICB9KTsKICAgIH0KICAgIGZ1bmN0aW9uIGhpZGVD
dHgoKSB7IGN0eEVsLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7IGN0eENsaXAgPSBudWxsOyB9CiAg
ICB3aW5kb3cuX19oaWRlQ3R4ID0gaGlkZUN0eDsKCiAgICBmdW5jdGlvbiBkaXNtaXNzQ3R4VW5s
ZXNzSW5zaWRlKGUpIHsKICAgICAgICBpZiAoIWN0eEVsLmNsYXNzTGlzdC5jb250YWlucygnb24n
KSkgcmV0dXJuOwogICAgICAgIGlmIChlLnRhcmdldC5jbG9zZXN0KCcjY3R4JykpIHJldHVybjsK
ICAgICAgICBoaWRlQ3R4KCk7CiAgICB9CiAgICBkb2N1bWVudC5hZGRFdmVudExpc3RlbmVyKCdt
b3VzZWRvd24nLCBkaXNtaXNzQ3R4VW5sZXNzSW5zaWRlLCB0cnVlKTsKICAgIGRvY3VtZW50LmFk
ZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZGlzbWlzc0N0eFVubGVzc0luc2lkZSwgdHJ1ZSk7CiAg
ICBsaXN0RWwuYWRkRXZlbnRMaXN0ZW5lcignc2Nyb2xsJywgaGlkZUN0eCwgeyBwYXNzaXZlOiB0
cnVlIH0pOwogICAgZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5lcigna2V5ZG93bicsIGUgPT4gewog
ICAgICAgIC8vIEVzYzogYWx3YXlzIGNsb3NlIHBhbmVsIChzZWFyY2ggb3Igbm90KTsgcGluIGtl
ZXBzIHBhbmVsCiAgICAgICAgaWYgKGUua2V5ID09PSAnRXNjYXBlJykgewogICAgICAgICAgICBl
LnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgIGhpZGVDdHgoKTsKICAgICAgICAgICAgY29u
c3QgdGQgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGl0bGUtZGxnJyk7CiAgICAgICAgICAg
IGlmICh0ZCAmJiB0ZC5jbGFzc0xpc3QuY29udGFpbnMoJ29uJykpIHsKICAgICAgICAgICAgICAg
IHRyeSB7IGNsb3NlVGl0bGVEbGcoKTsgfSBjYXRjaCB7IHRkLmNsYXNzTGlzdC5yZW1vdmUoJ29u
Jyk7IH0KICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAgICAgICAgICBp
ZiAoY2xyRGxnLmNsYXNzTGlzdC5jb250YWlucygnb24nKSkgewogICAgICAgICAgICAgICAgY2xv
c2VDbGVhckRsZygpOwogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICB9CiAgICAg
ICAgICAgIGlmICghcGlubmVkVUkpIGFoaygnaGlkZScpOwogICAgICAgICAgICByZXR1cm47CiAg
ICAgICAgfQogICAgICAgIC8vIFdoaWxlIHR5cGluZyBpbiBzZWFyY2g6IEN0cmwrSS9LIGFuZCBh
cnJvd3MgbW92ZSBsaXN0LCBkb24ndCBsZWF2ZSB0aGUgYm94CiAgICAgICAgaWYgKGRvY3VtZW50
LmFjdGl2ZUVsZW1lbnQ/LmlkID09PSAnc2VhcmNoJykgewogICAgICAgICAgICBpZiAoKGUuY3Ry
bEtleSB8fCBlLm1ldGFLZXkpICYmIChlLmtleSA9PT0gJ2knIHx8IGUua2V5ID09PSAnSScpKSB7
CiAgICAgICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0aW9uKCk7
CiAgICAgICAgICAgICAgICB3aW5kb3cuX19uYXYgJiYgd2luZG93Ll9fbmF2KCd1cCcpOwogICAg
ICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICB9CiAgICAgICAgICAgIGlmICgoZS5jdHJs
S2V5IHx8IGUubWV0YUtleSkgJiYgKGUua2V5ID09PSAnaycgfHwgZS5rZXkgPT09ICdLJykpIHsK
ICAgICAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsgZS5zdG9wUHJvcGFnYXRpb24oKTsK
ICAgICAgICAgICAgICAgIHdpbmRvdy5fX25hdiAmJiB3aW5kb3cuX19uYXYoJ2Rvd24nKTsKICAg
ICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAoZS5rZXkg
PT09ICdBcnJvd0Rvd24nKSB7CiAgICAgICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7IGUu
c3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgICAgICB3aW5kb3cuX19uYXYgJiYgd2luZG93
Ll9fbmF2KCdkb3duJyk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAg
ICAgICAgICAgaWYgKGUua2V5ID09PSAnQXJyb3dVcCcpIHsKICAgICAgICAgICAgICAgIGUucHJl
dmVudERlZmF1bHQoKTsgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgIHdpbmRv
dy5fX25hdiAmJiB3aW5kb3cuX19uYXYoJ3VwJyk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAg
ICAgICAgICAgIH0KICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBjb25zdCB2
aXMgPSAodHlwZW9mIG5hdkxpc3QgPT09ICdmdW5jdGlvbicgPyBuYXZMaXN0KCkgOiB2aXNpYmxl
TGlzdCgpKTsKICAgICAgICBpZiAoIXZpcy5sZW5ndGgpIHJldHVybjsKICAgICAgICBsZXQgaWR4
ID0gc2VsZWN0ZWRJbmRleCgpOwogICAgICAgIGlmIChpZHggPCAwKSBpZHggPSAwOwogICAgICAg
IGlmICAgICAgKGUua2V5ID09PSAnQXJyb3dEb3duJykgeyBlLnByZXZlbnREZWZhdWx0KCk7IGUu
c3RvcFByb3BhZ2F0aW9uKCk7IHNlbGVjdEJ5SW5kZXgoaWR4ICsgMSk7IH0KICAgICAgICBlbHNl
IGlmIChlLmtleSA9PT0gJ0Fycm93VXAnKSAgIHsgZS5wcmV2ZW50RGVmYXVsdCgpOyBlLnN0b3BQ
cm9wYWdhdGlvbigpOyBzZWxlY3RCeUluZGV4KGlkeCAtIDEpOyB9CiAgICAgICAgZWxzZSBpZiAo
ZS5rZXkgPT09ICdFbnRlcicpIHsKICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAg
ICAgICAgICBpZiAobXVsdGlJZHMubGVuZ3RoID4gMSkgewogICAgICAgICAgICAgICAgY29uc3Qg
aWRzID0gbXVsdGlJZHMuc2xpY2UoKTsKICAgICAgICAgICAgICAgIGNsZWFyTXVsdGkoKTsKICAg
ICAgICAgICAgICAgIG1hcmtQYXN0ZWRMb2NhbChpZHMpOwogICAgICAgICAgICAgICAgYWhrKCdw
YXN0ZU1hbnknLCBpZHMuam9pbignLCcpKTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAg
ICAgICAgfQogICAgICAgICAgICBpZiAobXVsdGlJZHMubGVuZ3RoID09PSAxKSB7CiAgICAgICAg
ICAgICAgICBjb25zdCBpZCA9IG11bHRpSWRzWzBdOwogICAgICAgICAgICAgICAgY2xlYXJNdWx0
aSgpOwogICAgICAgICAgICAgICAgbWFya1Bhc3RlZExvY2FsKGlkKTsKICAgICAgICAgICAgICAg
IGFoaygncGFzdGUnLCBTdHJpbmcoaWQpKTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAg
ICAgICAgfQogICAgICAgICAgICBjb25zdCBjID0gdmlzW3NlbGVjdGVkSW5kZXgoKV07CiAgICAg
ICAgICAgIGlmIChjKSB7CiAgICAgICAgICAgICAgICBtYXJrUGFzdGVkTG9jYWwoYy5pZCk7CiAg
ICAgICAgICAgICAgICBhaGsoJ3Bhc3RlJywgU3RyaW5nKGMuaWQpKTsKICAgICAgICAgICAgfQog
ICAgICAgIH0gZWxzZSBpZiAoL15bMS05XSQvLnRlc3QoZS5rZXkpKSB7CiAgICAgICAgICAgIGNv
bnN0IGMgPSB2aXNbK2Uua2V5IC0gMV07CiAgICAgICAgICAgIGlmIChjKSB7CiAgICAgICAgICAg
ICAgICBtYXJrUGFzdGVkTG9jYWwoYy5pZCk7CiAgICAgICAgICAgICAgICBhaGsoJ3Bhc3RlJywg
U3RyaW5nKGMuaWQpKTsKICAgICAgICAgICAgfQogICAgICAgIH0KICAgIH0pOwoKICAgIHdpbmRv
dy5fX25hdiA9IGRpciA9PiB7CiAgICAgICAgY29uc3QgdmlzID0gKHR5cGVvZiBuYXZMaXN0ID09
PSAnZnVuY3Rpb24nID8gbmF2TGlzdCgpIDogdmlzaWJsZUxpc3QoKSk7CiAgICAgICAgaWYgKCF2
aXMubGVuZ3RoICYmIGRpciAhPT0gJ3RhYicgJiYgZGlyICE9PSAndGFiUHJldicpIHJldHVybjsK
ICAgICAgICBsZXQgaWR4ID0gc2VsZWN0ZWRJbmRleCgpOwogICAgICAgIGlmIChpZHggPCAwKSBp
ZHggPSAwOwogICAgICAgIGlmIChkaXIgPT09ICd1cCcpIHNlbGVjdEJ5SW5kZXgoaWR4IC0gMSk7
CiAgICAgICAgZWxzZSBpZiAoZGlyID09PSAnZG93bicpIHNlbGVjdEJ5SW5kZXgoaWR4ICsgMSk7
CiAgICAgICAgZWxzZSBpZiAoZGlyID09PSAnZW50ZXInKSB7CiAgICAgICAgICAgIF9fcHJlcFBh
c3RlKCk7CiAgICAgICAgICAgIGlmIChtdWx0aUlkcy5sZW5ndGggPiAxKSB7CiAgICAgICAgICAg
ICAgICBjb25zdCBpZHMgPSBtdWx0aUlkcy5zbGljZSgpOwogICAgICAgICAgICAgICAgY2xlYXJN
dWx0aSgpOwogICAgICAgICAgICAgICAgbWFya1Bhc3RlZExvY2FsKGlkcyk7CiAgICAgICAgICAg
ICAgICBhaGsoJ3Bhc3RlTWFueScsIGlkcy5qb2luKCcsJykpOwogICAgICAgICAgICAgICAgcmV0
dXJuOwogICAgICAgICAgICB9CiAgICAgICAgICAgIGlmIChtdWx0aUlkcy5sZW5ndGggPT09IDEp
IHsKICAgICAgICAgICAgICAgIGNvbnN0IGlkID0gbXVsdGlJZHNbMF07CiAgICAgICAgICAgICAg
ICBjbGVhck11bHRpKCk7CiAgICAgICAgICAgICAgICBtYXJrUGFzdGVkTG9jYWwoaWQpOwogICAg
ICAgICAgICAgICAgYWhrKCdwYXN0ZScsIFN0cmluZyhpZCkpOwogICAgICAgICAgICAgICAgcmV0
dXJuOwogICAgICAgICAgICB9CiAgICAgICAgICAgIGNvbnN0IGMgPSB2aXNbc2VsZWN0ZWRJbmRl
eCgpXTsKICAgICAgICAgICAgaWYgKGMpIHsKICAgICAgICAgICAgICAgIG1hcmtQYXN0ZWRMb2Nh
bChjLmlkKTsKICAgICAgICAgICAgICAgIGFoaygncGFzdGUnLCBTdHJpbmcoYy5pZCkpOwogICAg
ICAgICAgICB9CiAgICAgICAgfQogICAgfTsKCiAgICAvLyBBSEsgRW50ZXIgaG90a2V5IGxhbmRz
IGhlcmUgKFdlYlZpZXcgbWF5IG5vdCByZWNlaXZlIHRoZSBrZXkgd2hpbGUgdW5waW5uZWQpCiAg
ICB3aW5kb3cuX19lZGl0VGl0bGUgPSAoKSA9PiB7CiAgICAgICAgbGV0IGMgPSBudWxsOwogICAg
ICAgIGlmIChzZWxlY3RlZElkKQogICAgICAgICAgICBjID0gYWxsQ2xpcHMuZmluZCh4ID0+ICt4
LmlkID09PSArc2VsZWN0ZWRJZCkgfHwgbnVsbDsKICAgICAgICBpZiAoIWMgJiYgY3R4Q2xpcCkK
ICAgICAgICAgICAgYyA9IGN0eENsaXA7CiAgICAgICAgaWYgKCFjKSB7CiAgICAgICAgICAgIGNv
bnN0IHZpcyA9IHZpc2libGVMaXN0KCk7CiAgICAgICAgICAgIGlmICh2aXMubGVuZ3RoKSBjID0g
dmlzWzBdOwogICAgICAgIH0KICAgICAgICBpZiAoIWMpIHJldHVybjsKICAgICAgICBvcGVuVGl0
bGVEbGcoYyk7CiAgICB9OwoKICAgIHdpbmRvdy5fX29uRW50ZXIgPSAoKSA9PiB7CiAgICAgICAg
Y29uc3QgdGQgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGl0bGUtZGxnJyk7CiAgICAgICAg
aWYgKHRkICYmIHRkLmNsYXNzTGlzdC5jb250YWlucygnb24nKSkgewogICAgICAgICAgICBkb2N1
bWVudC5nZXRFbGVtZW50QnlJZCgndGl0bGUtb2snKT8uY2xpY2soKTsKICAgICAgICAgICAgcmV0
dXJuOwogICAgICAgIH0KICAgICAgICBpZiAoZG9jdW1lbnQuYWN0aXZlRWxlbWVudD8uaWQgPT09
ICd0aXRsZS1pbnB1dCcpIHsKICAgICAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Rp
dGxlLW9rJyk/LmNsaWNrKCk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAg
Ly8gVHlwaW5nIGluIHNlYXJjaDogRW50ZXIgc2hvdWxkIHBhc3RlIHNlbGVjdGVkIGl0ZW0KICAg
ICAgICBpZiAoZG9jdW1lbnQuYWN0aXZlRWxlbWVudD8uaWQgPT09ICdzZWFyY2gnKSB7CiAgICAg
ICAgICAgIHdpbmRvdy5fX25hdiAmJiB3aW5kb3cuX19uYXYoJ2VudGVyJyk7CiAgICAgICAgICAg
IHJldHVybjsKICAgICAgICB9CiAgICAgICAgd2luZG93Ll9fbmF2ICYmIHdpbmRvdy5fX25hdign
ZW50ZXInKTsKICAgIH07CgogICAgd2luZG93Ll9fY3ljbGVUYWIgPSBkaXIgPT4gewogICAgICAg
IGNvbnN0IGkgPSBNYXRoLm1heCgwLCBUQUJfT1JERVIuaW5kZXhPZihjdXJUYWIpKTsKICAgICAg
ICBjb25zdCBuZXh0ID0gVEFCX09SREVSWyhpICsgKGRpciB8IDApICsgVEFCX09SREVSLmxlbmd0
aCAqIDEwKSAlIFRBQl9PUkRFUi5sZW5ndGhdOwogICAgICAgIHNldFRhYihuZXh0KTsKICAgIH07
CiAgICB3aW5kb3cuX19vblBhbmVsU2hvdyA9ICgpID0+IHsKICAgICAgICAvLyBEbyBOT1QgZm9j
dXMgV2ViVmlldyDigJQga2VlcCBlZGl0b3IgY2FyZXQvZm9jdXMgKEFISyBoYW5kbGVzIGtleXMg
dmlhICNIb3RJZikKICAgICAgICAvLyBDb2xsYXBzZSBzZWFyY2ggVUkgYW5kIGFsd2F5cyBsYW5k
IG9uIOWFqOmDqCBldmVyeSB0aW1lIHRoZSBwYW5lbCBvcGVucwogICAgICAgIHRyeSB7IGhpZGVD
dHgoKTsgfSBjYXRjaCB7fQogICAgICAgIHRyeSB7IGNsb3NlVGl0bGVEbGcoKTsgfSBjYXRjaCB7
fQogICAgICAgIHRyeSB7CiAgICAgICAgICAgIGNvbnN0IHdyYXAgPSBkb2N1bWVudC5nZXRFbGVt
ZW50QnlJZCgnc2VhcmNoLXdyYXAnKTsKICAgICAgICAgICAgY29uc3Qgc3JjaCA9IGRvY3VtZW50
LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gnKTsKICAgICAgICAgICAgY29uc3Qgc2NsciA9IGRvY3Vt
ZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gtY2xyJyk7CiAgICAgICAgICAgIGlmICh3cmFwKSB3
cmFwLmNsYXNzTGlzdC5yZW1vdmUoJ29wZW4nKTsKICAgICAgICAgICAgaWYgKHNyY2gpIHsKICAg
ICAgICAgICAgICAgIHNyY2gudmFsdWUgPSAnJzsKICAgICAgICAgICAgICAgIHNyY2guY2xhc3NM
aXN0LnJlbW92ZSgnaGFzLXZhbCcpOwogICAgICAgICAgICAgICAgdHJ5IHsgc3JjaC5ibHVyKCk7
IH0gY2F0Y2gge30KICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAoc2Nscikgc2Nsci5zdHls
ZS5kaXNwbGF5ID0gJ25vbmUnOwogICAgICAgICAgICBxdWVyeSA9ICcnOwogICAgICAgICAgICB0
b2RheU9ubHkgPSBmYWxzZTsKICAgICAgICAgICAgdHJ5IHsKICAgICAgICAgICAgICAgIGNvbnN0
IGJ0blRvZGF5ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi10b2RheScpOwogICAgICAg
ICAgICAgICAgaWYgKGJ0blRvZGF5KSBidG5Ub2RheS5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwog
ICAgICAgICAgICB9IGNhdGNoIHt9CiAgICAgICAgICAgIGN1clRhYiA9ICdhbGwnOwogICAgICAg
ICAgICBsb2FkaW5nTW9yZSA9IGZhbHNlOwogICAgICAgICAgICBtYXJrVGFiKCdhbGwnKTsKICAg
ICAgICAgICAgdHJ5IHsgYWhrKCdibHVyUGFuZWwnKTsgfSBjYXRjaCB7fQogICAgICAgICAgICAv
LyBEZWxheSBza2VsZXRvbjogc2hvdyBvbmx5IGlmIGRhdGEgaXMgc2xvdyAoPjE4MG1zIG5vIHJl
c3BvbnNlKQogICAgICAgICAgICBpZiAod2luZG93Ll9fcGVuZGluZ1NrZWxUaW1lcikgY2xlYXJU
aW1lb3V0KHdpbmRvdy5fX3BlbmRpbmdTa2VsVGltZXIpOwogICAgICAgICAgICB3aW5kb3cuX19w
ZW5kaW5nU2tlbFNpbmNlID0gRGF0ZS5ub3coKTsKICAgICAgICAgICAgd2luZG93Ll9fcGVuZGlu
Z1NrZWxUaW1lciA9IHNldFRpbWVvdXQoKCkgPT4gewogICAgICAgICAgICAgICAgd2luZG93Ll9f
cGVuZGluZ1NrZWxUaW1lciA9IDA7CiAgICAgICAgICAgICAgICBpZiAoIXdpbmRvdy5fX2RhdGFS
ZWFkeSkgc2V0Qm9vdExvYWRpbmcodHJ1ZSk7CiAgICAgICAgICAgIH0sIDE4MCk7CiAgICAgICAg
ICAgIHJlbmRlcigpOwogICAgICAgIH0gY2F0Y2gge30KICAgICAgICBzZWxlY3RGaXJzdE9uU2hv
dyA9IHRydWU7CiAgICAgICAgbG9jYXRlQWN0aXZlID0gZmFsc2U7CiAgICAgICAgdXBkYXRlTG9j
YXRlQnRuKCk7CiAgICAgICAgY2xlYXJNdWx0aSgpOwogICAgICAgIGNvbnN0IHZpcyA9IHZpc2li
bGVMaXN0KCk7CiAgICAgICAgaWYgKHZpcy5sZW5ndGgpIHsKICAgICAgICAgICAgc2VsZWN0ZWRJ
ZCA9IHZpc1swXS5pZDsKICAgICAgICAgICAgcmFuZ2VBbmNob3JJZCA9IHNlbGVjdGVkSWQ7CiAg
ICAgICAgICAgIHJhbmdlQW5jaG9yQ2xpY2tlZCA9IGZhbHNlOwogICAgICAgICAgICBsaXN0RWwu
c2Nyb2xsVG9wID0gMDsKICAgICAgICB9CiAgICAgICAgc3luY0l0ZW1IaWdobGlnaHQoKTsKICAg
IH07CgogICAgZnVuY3Rpb24gY3R4QmluZChpZCwgZm4pIHsKICAgICAgICBkb2N1bWVudC5nZXRF
bGVtZW50QnlJZChpZCkuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICAg
ICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgaWYgKGN0eENsaXApIGZuKGN0eENs
aXApOwogICAgICAgICAgICBoaWRlQ3R4KCk7CiAgICAgICAgfSk7CiAgICB9CiAgICBjdHhCaW5k
KCdjLWNvcHknLCAgYyA9PiBhaGsoJ2NvcHlCeUlkJywgICAgIFN0cmluZyhjLmlkKSkpOwogICAg
Y3R4QmluZCgnYy1wYXN0ZScsIGMgPT4gewogICAgICAgIG1hcmtQYXN0ZWRMb2NhbChjLmlkKTsK
ICAgICAgICBhaGsoJ3Bhc3RlJywgU3RyaW5nKGMuaWQpKTsKICAgIH0pOwogICAgY3R4QmluZCgn
Yy1waW4nLCAgIGMgPT4gYWhrKCdwaW4nLCAgICAgICAgICAgU3RyaW5nKGMuaWQpKSk7CiAgICBj
dHhCaW5kKCdjLXRvcCcsICAgYyA9PiBhaGsoJ21vdmVUb1RvcCcsICAgICBTdHJpbmcoYy5pZCkp
KTsKICAgIGN0eEJpbmQoJ2MtY2xlYXItcGFzdGVkJywgYyA9PiBhaGsoJ2NsZWFyUGFzdGVkJywg
U3RyaW5nKGMuaWQpKSk7CiAgICBjdHhCaW5kKCdjLWRlbCcsICAgYyA9PiBhaGsoJ2RlbGV0ZScs
ICAgICAgICBTdHJpbmcoYy5pZCkpKTsKICAgIGN0eEJpbmQoJ2MtdGl0bGUnLCBjID0+IG9wZW5U
aXRsZURsZyhjKSk7CiAgICBjdHhCaW5kKCdjLW1lcmdlJywgYyA9PiB7CiAgICAgICAgY29uc3Qg
aWRzID0gKG11bHRpSWRzLmxlbmd0aCA+PSAyKSA/IG11bHRpSWRzLnNsaWNlKCkgOiBbXTsKICAg
ICAgICBpZiAoaWRzLmxlbmd0aCA8IDIpIHJldHVybjsKICAgICAgICBpZiAoIWlkcy5pbmNsdWRl
cygrYy5pZCkpIGlkcy5wdXNoKCtjLmlkKTsKICAgICAgICBhaGsoJ21lcmdlRmF2JywgaWRzLmpv
aW4oJywnKSk7CiAgICAgICAgY2xlYXJNdWx0aSgpOwogICAgfSk7CiAgICBjdHhCaW5kKCdjLXVu
bWVyZ2UnLCBjID0+IHsKICAgICAgICBhaGsoJ3VubWVyZ2VGYXYnLCBTdHJpbmcoYy5pZCkpOwog
ICAgICAgIGNsZWFyTXVsdGkoKTsKICAgIH0pOwoKICAgIGNvbnN0IHRpdGxlRGxnID0gZG9jdW1l
bnQuZ2V0RWxlbWVudEJ5SWQoJ3RpdGxlLWRsZycpOwogICAgY29uc3QgdGl0bGVJbnB1dCA9IGRv
Y3VtZW50LmdldEVsZW1lbnRCeUlkKCd0aXRsZS1pbnB1dCcpOwogICAgbGV0IHRpdGxlRGxnQ2xp
cCA9IG51bGw7CiAgICBmdW5jdGlvbiBjbG9zZVRpdGxlRGxnKCkgewogICAgICAgIGlmICh0aXRs
ZURsZykgdGl0bGVEbGcuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICB0aXRsZURsZ0Ns
aXAgPSBudWxsOwogICAgfQogICAgZnVuY3Rpb24gb3BlblRpdGxlRGxnKGMpIHsKICAgICAgICBo
aWRlQ3R4KCk7CiAgICAgICAgdGl0bGVEbGdDbGlwID0gYzsKICAgICAgICBpZiAodGl0bGVJbnB1
dCkgdGl0bGVJbnB1dC52YWx1ZSA9IFN0cmluZyhjLmZhdlRpdGxlIHx8ICcnKS50cmltKCk7CiAg
ICAgICAgaWYgKHRpdGxlRGxnKSB0aXRsZURsZy5jbGFzc0xpc3QuYWRkKCdvbicpOwogICAgICAg
IGFoaygnZm9jdXNQYW5lbCcpOwogICAgICAgIHJlcXVlc3RBbmltYXRpb25GcmFtZSgoKSA9PiB7
CiAgICAgICAgICAgIHRyeSB7IHRpdGxlSW5wdXQuZm9jdXMoKTsgdGl0bGVJbnB1dC5zZWxlY3Qo
KTsgfSBjYXRjaCB7fQogICAgICAgIH0pOwogICAgfQogICAgaWYgKHRpdGxlRGxnKSB7CiAgICAg
ICAgdGl0bGVEbGcuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICAgICAg
aWYgKGUudGFyZ2V0ID09PSB0aXRsZURsZykgY2xvc2VUaXRsZURsZygpOwogICAgICAgIH0pOwog
ICAgfQogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RpdGxlLWNhbmNlbCcpPy5hZGRFdmVu
dExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAg
ICAgICAgY2xvc2VUaXRsZURsZygpOwogICAgICAgIGFoaygnYmx1clBhbmVsJyk7CiAgICB9KTsK
ICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0aXRsZS1vaycpPy5hZGRFdmVudExpc3RlbmVy
KCdjbGljaycsIGUgPT4gewogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgaWYg
KCF0aXRsZURsZ0NsaXApIHJldHVybjsKICAgICAgICBjb25zdCB0ID0gU3RyaW5nKHRpdGxlSW5w
dXQ/LnZhbHVlIHx8ICcnKS50cmltKCkuc2xpY2UoMCwgODApOwogICAgICAgIGNvbnN0IGlkID0g
U3RyaW5nKHRpdGxlRGxnQ2xpcC5pZCk7CiAgICAgICAgLy8gT3B0aW1pc3RpYyBsb2NhbCB1cGRh
dGUKICAgICAgICBjb25zdCBoaXQgPSBhbGxDbGlwcy5maW5kKHggPT4gK3guaWQgPT09ICtpZCk7
CiAgICAgICAgaWYgKGhpdCkgaGl0LmZhdlRpdGxlID0gdDsKICAgICAgICB0aXRsZURsZ0NsaXAu
ZmF2VGl0bGUgPSB0OwogICAgICAgIGNsb3NlVGl0bGVEbGcoKTsKICAgICAgICBhaGsoJ3NldEZh
dlRpdGxlJywgaWQsIHQpOwogICAgICAgIGFoaygnYmx1clBhbmVsJyk7CiAgICAgICAgcmVuZGVy
KCk7CiAgICB9KTsKICAgIHRpdGxlSW5wdXQ/LmFkZEV2ZW50TGlzdGVuZXIoJ2tleWRvd24nLCBl
ID0+IHsKICAgICAgICBpZiAoZS5rZXkgPT09ICdFbnRlcicpIHsKICAgICAgICAgICAgZS5wcmV2
ZW50RGVmYXVsdCgpOwogICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAg
ICBlLnN0b3BJbW1lZGlhdGVQcm9wYWdhdGlvbigpOwogICAgICAgICAgICBkb2N1bWVudC5nZXRF
bGVtZW50QnlJZCgndGl0bGUtb2snKT8uY2xpY2soKTsKICAgICAgICAgICAgcmV0dXJuOwogICAg
ICAgIH0KICAgICAgICBpZiAoZS5rZXkgPT09ICdFc2NhcGUnKSB7CiAgICAgICAgICAgIGUucHJl
dmVudERlZmF1bHQoKTsKICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAg
ICAgY2xvc2VUaXRsZURsZygpOwogICAgICAgICAgICBhaGsoJ2JsdXJQYW5lbCcpOwogICAgICAg
ICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICB9
LCB0cnVlKTsKCiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGFicycpLmFkZEV2ZW50TGlz
dGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgY29uc3QgdGFiID0gZS50YXJnZXQuY2xvc2Vz
dCgnLnRhYicpOwogICAgICAgIGlmICghdGFiIHx8IGUudGFyZ2V0LmNsb3Nlc3QoJyN0YWItYWN0
aW9ucycpKSByZXR1cm47CiAgICAgICAgc2V0VGFiKHRhYi5kYXRhc2V0LnRhYik7CiAgICB9KTsK
CiAgICBjb25zdCBzcmNoV3JhcCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gtd3Jh
cCcpOwogICAgY29uc3QgYnRuU2VhcmNoID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi1z
ZWFyY2gnKTsKICAgIGNvbnN0IGJ0bkxvY2F0ZSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdi
dG4tbG9jYXRlJyk7CiAgICBjb25zdCBidG5Ub2RheSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlk
KCdidG4tdG9kYXknKTsKICAgIGNvbnN0IHNyY2ggPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgn
c2VhcmNoJyk7CiAgICBjb25zdCBzY2xyID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJj
aC1jbHInKTsKICAgIGxldCBkZWI7CgogICAgdXBkYXRlTG9jYXRlQnRuKCk7CiAgICBpZiAoYnRu
TG9jYXRlKSB7CiAgICAgICAgYnRuTG9jYXRlLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9
PiB7CiAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgIGp1bXBUb0xh
c3RQYXN0ZSgpOwogICAgICAgIH0pOwogICAgfQoKICAgIGJ0blRvZGF5LmFkZEV2ZW50TGlzdGVu
ZXIoJ21vdXNlZG93bicsIGUgPT4gewogICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAg
ICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgfSk7CiAgICBidG5Ub2RheS5hZGRFdmVudExpc3Rl
bmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAg
ZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgIHRvZGF5T25seSA9ICF0b2RheU9ubHk7CiAgICAg
ICAgYnRuVG9kYXkuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCB0b2RheU9ubHkpOwogICAgICAgIGxp
c3RFbC5zY3JvbGxUb3AgPSAwOwogICAgICAgIHJlcXVlc3RWaWV3KCk7CiAgICAgICAgdHJ5IHsg
c3JjaC5mb2N1cygpOyB9IGNhdGNoIHt9CiAgICB9KTsKCiAgICBmdW5jdGlvbiBvcGVuU2VhcmNo
KCkgewogICAgICAgIGlmIChzcmNoV3JhcC5jbGFzc0xpc3QuY29udGFpbnMoJ29wZW4nKSkgewog
ICAgICAgICAgICBhaGsoJ2ZvY3VzUGFuZWwnKTsKICAgICAgICAgICAgdHJ5IHsgc3JjaC5mb2N1
cygpOyB9IGNhdGNoIHt9CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgc3Jj
aFdyYXAuY2xhc3NMaXN0LmFkZCgnb3BlbicpOwogICAgICAgIC8vIERlZmF1bHQ6IOaJgOaciemh
teaJk+W8gOaQnOe0ouaXtum7mOiupOaQnOWFqOmDqAogICAgICAgIGNvbnN0IHdhbnRUb2RheSA9
IGZhbHNlOwogICAgICAgIGlmICh0b2RheU9ubHkgIT09IHdhbnRUb2RheSkgewogICAgICAgICAg
ICB0b2RheU9ubHkgPSB3YW50VG9kYXk7CiAgICAgICAgICAgIGJ0blRvZGF5LmNsYXNzTGlzdC50
b2dnbGUoJ29uJywgdG9kYXlPbmx5KTsKICAgICAgICAgICAgbGlzdEVsLnNjcm9sbFRvcCA9IDA7
CiAgICAgICAgICAgIHJlcXVlc3RWaWV3KCk7CiAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAg
YnRuVG9kYXkuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCB0b2RheU9ubHkpOwogICAgICAgIH0KICAg
ICAgICBhaGsoJ2ZvY3VzUGFuZWwnKTsKICAgICAgICByZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkg
PT4gewogICAgICAgICAgICB0cnkgeyBzcmNoLmZvY3VzKCk7IH0gY2F0Y2gge30KICAgICAgICB9
KTsKICAgIH0KICAgIGZ1bmN0aW9uIGNsb3NlU2VhcmNoVWkoKSB7CiAgICAgICAgc3JjaFdyYXAu
Y2xhc3NMaXN0LnJlbW92ZSgnb3BlbicpOwogICAgICAgIGlmICghc3JjaC52YWx1ZSkgewogICAg
ICAgICAgICBzcmNoLmNsYXNzTGlzdC5yZW1vdmUoJ2hhcy12YWwnKTsKICAgICAgICAgICAgc2Ns
ci5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOwogICAgICAgICAgICAvLyBMZWF2aW5nIHNlYXJjaCB3
aXRoIGVtcHR5IHF1ZXJ5IOKGkiBkcm9wIHRvZGF5IGZpbHRlcgogICAgICAgICAgICBpZiAodG9k
YXlPbmx5KSB7CiAgICAgICAgICAgICAgICB0b2RheU9ubHkgPSBmYWxzZTsKICAgICAgICAgICAg
ICAgIGJ0blRvZGF5LmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgICAgICAgICByZXF1
ZXN0VmlldygpOwogICAgICAgICAgICB9CiAgICAgICAgfQogICAgfQogICAgd2luZG93Ll9fb3Bl
blNlYXJjaCA9IG9wZW5TZWFyY2g7CiAgICB3aW5kb3cuX19wcmVwVHlwZVNlYXJjaCA9ICgpID0+
IHsKICAgICAgICB0cnkgewogICAgICAgICAgICBjb25zdCB3cmFwID0gZG9jdW1lbnQuZ2V0RWxl
bWVudEJ5SWQoJ3NlYXJjaC13cmFwJyk7CiAgICAgICAgICAgIGNvbnN0IHMgPSBkb2N1bWVudC5n
ZXRFbGVtZW50QnlJZCgnc2VhcmNoJyk7CiAgICAgICAgICAgIGlmICh3cmFwICYmICF3cmFwLmNs
YXNzTGlzdC5jb250YWlucygnb3BlbicpKSB7CiAgICAgICAgICAgICAgICB3cmFwLmNsYXNzTGlz
dC5hZGQoJ29wZW4nKTsKICAgICAgICAgICAgICAgIHRyeSB7CiAgICAgICAgICAgICAgICAgICAg
Y29uc3Qgd2FudFRvZGF5ID0gZmFsc2U7CiAgICAgICAgICAgICAgICAgICAgaWYgKHR5cGVvZiB0
b2RheU9ubHkgIT09ICd1bmRlZmluZWQnICYmIHRvZGF5T25seSAhPT0gd2FudFRvZGF5KSB7CiAg
ICAgICAgICAgICAgICAgICAgICAgIHRvZGF5T25seSA9IHdhbnRUb2RheTsKICAgICAgICAgICAg
ICAgICAgICAgICAgaWYgKHR5cGVvZiBidG5Ub2RheSAhPT0gJ3VuZGVmaW5lZCcgJiYgYnRuVG9k
YXkpIGJ0blRvZGF5LmNsYXNzTGlzdC50b2dnbGUoJ29uJywgdG9kYXlPbmx5KTsKICAgICAgICAg
ICAgICAgICAgICAgICAgaWYgKHR5cGVvZiBsaXN0RWwgIT09ICd1bmRlZmluZWQnICYmIGxpc3RF
bCkgbGlzdEVsLnNjcm9sbFRvcCA9IDA7CiAgICAgICAgICAgICAgICAgICAgICAgIGlmICh0eXBl
b2YgcmVxdWVzdFZpZXcgPT09ICdmdW5jdGlvbicpIHNldFRpbWVvdXQocmVxdWVzdFZpZXcsIDAp
OwogICAgICAgICAgICAgICAgICAgIH0gZWxzZSBpZiAodHlwZW9mIGJ0blRvZGF5ICE9PSAndW5k
ZWZpbmVkJyAmJiBidG5Ub2RheSkgewogICAgICAgICAgICAgICAgICAgICAgICBidG5Ub2RheS5j
bGFzc0xpc3QudG9nZ2xlKCdvbicsICEhdG9kYXlPbmx5KTsKICAgICAgICAgICAgICAgICAgICB9
CiAgICAgICAgICAgICAgICB9IGNhdGNoIHt9CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYg
KHMpIHsgdHJ5IHsgcy5mb2N1cygpOyB9IGNhdGNoIHt9IH0KICAgICAgICB9IGNhdGNoIHt9CiAg
ICB9OwogICAgd2luZG93Ll9fdHlwZVNlYXJjaCA9IChjaCkgPT4gewogICAgICAgIHRyeSB7CiAg
ICAgICAgICAgIHdpbmRvdy5fX3ByZXBUeXBlU2VhcmNoICYmIHdpbmRvdy5fX3ByZXBUeXBlU2Vh
cmNoKCk7CiAgICAgICAgICAgIGNvbnN0IHMgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2Vh
cmNoJyk7CiAgICAgICAgICAgIGlmICghcykgcmV0dXJuOwogICAgICAgICAgICBzLnZhbHVlID0g
U3RyaW5nKHMudmFsdWUgfHwgJycpICsgU3RyaW5nKGNoID09IG51bGwgPyAnJyA6IGNoKTsKICAg
ICAgICAgICAgcy5jbGFzc0xpc3QudG9nZ2xlKCdoYXMtdmFsJywgISFzLnZhbHVlKTsKICAgICAg
ICAgICAgcy5kaXNwYXRjaEV2ZW50KG5ldyBFdmVudCgnaW5wdXQnLCB7IGJ1YmJsZXM6IHRydWUg
fSkpOwogICAgICAgIH0gY2F0Y2gge30KICAgIH07CiAgICB3aW5kb3cuX19ia3NwU2VhcmNoID0g
KCkgPT4gewogICAgICAgIHRyeSB7CiAgICAgICAgICAgIHdpbmRvdy5fX3ByZXBUeXBlU2VhcmNo
ICYmIHdpbmRvdy5fX3ByZXBUeXBlU2VhcmNoKCk7CiAgICAgICAgICAgIGNvbnN0IHMgPSBkb2N1
bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoJyk7CiAgICAgICAgICAgIGlmICghcykgcmV0dXJu
OwogICAgICAgICAgICBjb25zdCB2ID0gU3RyaW5nKHMudmFsdWUgfHwgJycpOwogICAgICAgICAg
ICBzLnZhbHVlID0gdi5sZW5ndGggPyB2LnNsaWNlKDAsIC0xKSA6ICcnOwogICAgICAgICAgICBz
LmNsYXNzTGlzdC50b2dnbGUoJ2hhcy12YWwnLCAhIXMudmFsdWUpOwogICAgICAgICAgICBzLmRp
c3BhdGNoRXZlbnQobmV3IEV2ZW50KCdpbnB1dCcsIHsgYnViYmxlczogdHJ1ZSB9KSk7CiAgICAg
ICAgfSBjYXRjaCB7fQogICAgfTsKICAgIC8vIENhcHR1cmUgQ3RybCtGIGluc2lkZSBXZWJWaWV3
IChDaHJvbWl1bSBmaW5kIGlzIGRpc2FibGVkLCBidXQgc3RpbGwgaGFuZGxlIGhlcmUpCiAgICBk
b2N1bWVudC5hZGRFdmVudExpc3RlbmVyKCdrZXlkb3duJywgZSA9PiB7CiAgICAgICAgaWYgKChl
LmN0cmxLZXkgfHwgZS5tZXRhS2V5KSAmJiAhZS5hbHRLZXkgJiYgKGUua2V5ID09PSAnZicgfHwg
ZS5rZXkgPT09ICdGJykpIHsKICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAg
ICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICBvcGVuU2VhcmNoKCk7CiAgICAg
ICAgfQogICAgfSwgdHJ1ZSk7CiAgICBidG5TZWFyY2guYWRkRXZlbnRMaXN0ZW5lcignY2xpY2sn
LCBlID0+IHsKICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgIG9wZW5TZWFyY2go
KTsKICAgIH0pOwogICAgbGV0IF9fc3JjaENvbXBvc2luZyA9IGZhbHNlOwogICAgY29uc3QgX19m
bHVzaFNlYXJjaElucHV0ID0gKCkgPT4gewogICAgICAgIHF1ZXJ5ID0gc3JjaC52YWx1ZTsKICAg
ICAgICBzcmNoLmNsYXNzTGlzdC50b2dnbGUoJ2hhcy12YWwnLCAhIXF1ZXJ5KTsKICAgICAgICBz
Y2xyLnN0eWxlLmRpc3BsYXkgPSBxdWVyeSA/ICdibG9jaycgOiAnbm9uZSc7CiAgICAgICAgbGlz
dEVsLnNjcm9sbFRvcCA9IDA7CiAgICAgICAgY2xlYXJUaW1lb3V0KGRlYik7CiAgICAgICAgZGVi
ID0gc2V0VGltZW91dChyZXF1ZXN0VmlldywgMTgwKTsKICAgIH07CiAgICBzcmNoLmFkZEV2ZW50
TGlzdGVuZXIoJ2NvbXBvc2l0aW9uc3RhcnQnLCAoKSA9PiB7IF9fc3JjaENvbXBvc2luZyA9IHRy
dWU7IH0pOwogICAgc3JjaC5hZGRFdmVudExpc3RlbmVyKCdjb21wb3NpdGlvbmVuZCcsICgpID0+
IHsKICAgICAgICBfX3NyY2hDb21wb3NpbmcgPSBmYWxzZTsKICAgICAgICBfX2ZsdXNoU2VhcmNo
SW5wdXQoKTsKICAgIH0pOwogICAgc3JjaC5hZGRFdmVudExpc3RlbmVyKCdpbnB1dCcsICgpID0+
IHsKICAgICAgICBpZiAoX19zcmNoQ29tcG9zaW5nKSB7CiAgICAgICAgICAgIHF1ZXJ5ID0gc3Jj
aC52YWx1ZTsKICAgICAgICAgICAgc3JjaC5jbGFzc0xpc3QudG9nZ2xlKCdoYXMtdmFsJywgISFx
dWVyeSk7CiAgICAgICAgICAgIHNjbHIuc3R5bGUuZGlzcGxheSA9IHF1ZXJ5ID8gJ2Jsb2NrJyA6
ICdub25lJzsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBfX2ZsdXNoU2Vh
cmNoSW5wdXQoKTsKICAgIH0pOwogICAgc3JjaC5hZGRFdmVudExpc3RlbmVyKCdmb2N1cycsICgp
ID0+IHsKICAgICAgICAvLyBJZGVtcG90ZW50IG9uIEFISyBzaWRlIOKAlCBzYWZlLCBidXQgYXZv
aWQgc3BhbW1pbmcgZHVyaW5nIElNRQogICAgICAgIHRyeSB7IGFoaygnZm9jdXNQYW5lbCcpOyB9
IGNhdGNoIHt9CiAgICB9KTsKICAgIHNyY2guYWRkRXZlbnRMaXN0ZW5lcignYmx1cicsICgpID0+
IHsKICAgICAgICBzZXRUaW1lb3V0KCgpID0+IHsKICAgICAgICAgICAgaWYgKGRvY3VtZW50LmFj
dGl2ZUVsZW1lbnQgPT09IHNyY2gpIHJldHVybjsKICAgICAgICAgICAgaWYgKGRvY3VtZW50LmFj
dGl2ZUVsZW1lbnQgPT09IHNjbHIgfHwgKHNjbHIgJiYgc2Nsci5jb250YWlucyhkb2N1bWVudC5h
Y3RpdmVFbGVtZW50KSkpIHJldHVybjsKICAgICAgICAgICAgaWYgKGRvY3VtZW50LmFjdGl2ZUVs
ZW1lbnQgPT09IGJ0blRvZGF5IHx8IChidG5Ub2RheSAmJiBidG5Ub2RheS5jb250YWlucyhkb2N1
bWVudC5hY3RpdmVFbGVtZW50KSkpIHJldHVybjsKICAgICAgICAgICAgLy8gSU1FIGNhbmRpZGF0
ZSBVSSBzdGVhbHMgZm9jdXMgYnJpZWZseSDigJQga2VlcCBzZWFyY2ggaWYgc3RpbGwgY29tcG9z
aW5nCiAgICAgICAgICAgIGlmIChfX3NyY2hDb21wb3NpbmcpIHJldHVybjsKICAgICAgICAgICAg
Y2xvc2VTZWFyY2hVaSgpOwogICAgICAgICAgICBhaGsoJ2JsdXJQYW5lbCcpOwogICAgICAgIH0s
IDI4MCk7CiAgICB9KTsKICAgIHNyY2guYWRkRXZlbnRMaXN0ZW5lcigna2V5ZG93bicsIGUgPT4g
ewogICAgICAgIC8vIEN0cmwrSSAvIEN0cmwrSzogbW92ZSBjbGlwIHNlbGVjdGlvbiAobm90IGlu
c2VydCBjaGFyIC8gYnJvd3NlciBzaG9ydGN1dCkKICAgICAgICBpZiAoKGUuY3RybEtleSB8fCBl
Lm1ldGFLZXkpICYmIChlLmtleSA9PT0gJ2knIHx8IGUua2V5ID09PSAnSScpKSB7CiAgICAgICAg
ICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsK
ICAgICAgICAgICAgd2luZG93Ll9fbmF2ICYmIHdpbmRvdy5fX25hdigndXAnKTsKICAgICAgICAg
ICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBpZiAoKGUuY3RybEtleSB8fCBlLm1ldGFLZXkp
ICYmIChlLmtleSA9PT0gJ2snIHx8IGUua2V5ID09PSAnSycpKSB7CiAgICAgICAgICAgIGUucHJl
dmVudERlZmF1bHQoKTsKICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAg
ICAgd2luZG93Ll9fbmF2ICYmIHdpbmRvdy5fX25hdignZG93bicpOwogICAgICAgICAgICByZXR1
cm47CiAgICAgICAgfQogICAgICAgIGlmIChlLmtleSA9PT0gJ0Fycm93RG93bicpIHsKICAgICAg
ICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigp
OwogICAgICAgICAgICB3aW5kb3cuX19uYXYgJiYgd2luZG93Ll9fbmF2KCdkb3duJyk7CiAgICAg
ICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgaWYgKGUua2V5ID09PSAnQXJyb3dVcCcp
IHsKICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICBlLnN0b3BQcm9w
YWdhdGlvbigpOwogICAgICAgICAgICB3aW5kb3cuX19uYXYgJiYgd2luZG93Ll9fbmF2KCd1cCcp
OwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGlmIChlLmtleSA9PT0gJ0Vz
Y2FwZScpIHsKICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICBlLnN0
b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAvLyBBbHdheXMgZGlzbWlzcyB0aGUgd2hvbGUg
cGFuZWwgKG5vdCBqdXN0IHRoZSBzZWFyY2ggZmllbGQpCiAgICAgICAgICAgIGlmICghcGlubmVk
VUkpIGFoaygnaGlkZScpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGUu
c3RvcFByb3BhZ2F0aW9uKCk7CiAgICB9KTsKICAgIHNjbHIuYWRkRXZlbnRMaXN0ZW5lcignY2xp
Y2snLCBlID0+IHsKICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgIHNyY2gudmFs
dWUgPSBxdWVyeSA9ICcnOwogICAgICAgIHNjbHIuc3R5bGUuZGlzcGxheSA9ICdub25lJzsKICAg
ICAgICBzcmNoLmNsYXNzTGlzdC5yZW1vdmUoJ2hhcy12YWwnKTsKICAgICAgICByZXF1ZXN0Vmll
dygpOwogICAgICAgIGFoaygnZm9jdXNQYW5lbCcpOwogICAgICAgIHNyY2guZm9jdXMoKTsKICAg
IH0pOwoKICAgIGNvbnN0IFRBQl9OQU1FUyA9IHsgYWxsOiAn5YWo6YOoJywgdGV4dDogJ+aWh+ac
rCcsIGltYWdlOiAn5Zu+5YOPJywgZmlsZTogJ+aWh+S7ticsIHBpbm5lZDogJ+aUtuiXjycgfTsK
ICAgIGNvbnN0IGNsckRsZyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjbHItZGxnJyk7CiAg
ICBjb25zdCBjbHJBbGxDYiA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjbHItYWxsJyk7CiAg
ICBmdW5jdGlvbiBvcGVuQ2xlYXJEbGcoKSB7CiAgICAgICAgY29uc3QgbmFtZSA9IFRBQl9OQU1F
U1tjdXJUYWJdIHx8ICflvZPliY0nOwogICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdj
bHItdGl0bGUnKS50ZXh0Q29udGVudCA9ICfmuIXnqbrjgIwnICsgbmFtZSArICfjgI3vvJ8nOwog
ICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjbHItZGVzYycpLnRleHRDb250ZW50ID0g
Y3VyVGFiID09PSAncGlubmVkJwogICAgICAgICAgICA/ICfpu5jorqTku4XmuIXnqbrlvZPlpKnn
moTmlLbol4/pobnjgILli77pgInjgIzmuIXnqbrmiYDmnInjgI3lj6/muIXpmaTor6XpgInpobnl
jaHlhajpg6jlhoXlrrnjgIInCiAgICAgICAgICAgIDogJ+S7hea4heepuuW9k+WJjemAiemhueWN
oeOAgum7mOiupOWPqua4heW9k+Wkqe+8m+aUtuiXj+mhueS4jeS8muiiq+a4hemZpOOAguWLvumA
ieOAjOa4heepuuaJgOacieOAjeWPr+a4hemZpOivpemAiemhueWNoeWFqOmDqOaXpeacn+OAgic7
CiAgICAgICAgY2xyQWxsQ2IuY2hlY2tlZCA9IGZhbHNlOwogICAgICAgIGNsckRsZy5jbGFzc0xp
c3QuYWRkKCdvbicpOwogICAgfQogICAgZnVuY3Rpb24gY2xvc2VDbGVhckRsZygpIHsKICAgICAg
ICBjbHJEbGcuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgIH0KICAgIGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCdidG4tY2xyJykuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAg
ICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgIG9wZW5DbGVhckRsZygpOwogICAgfSk7
CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2xyLWNhbmNlbCcpLmFkZEV2ZW50TGlzdGVu
ZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICBj
bG9zZUNsZWFyRGxnKCk7CiAgICB9KTsKICAgIGNsckRsZy5hZGRFdmVudExpc3RlbmVyKCdjbGlj
aycsIGUgPT4gewogICAgICAgIGlmIChlLnRhcmdldCA9PT0gY2xyRGxnKSBjbG9zZUNsZWFyRGxn
KCk7CiAgICB9KTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjbHItb2snKS5hZGRFdmVu
dExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAg
ICAgICAgY29uc3Qgc2NvcGUgPSBjbHJBbGxDYi5jaGVja2VkID8gJ2FsbCcgOiAndG9kYXknOwog
ICAgICAgIGNsb3NlQ2xlYXJEbGcoKTsKICAgICAgICBhaGsoJ2NsZWFyJywgY3VyVGFiLCBzY29w
ZSk7CiAgICB9KTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtdWx0aS1jbnQnKS5hZGRF
dmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7
CiAgICAgICAgY2xlYXJNdWx0aSh0cnVlKTsKICAgIH0pOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVu
dEJ5SWQoJ2J0bi1waW4nKS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAg
IGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgcGlubmVkVUkgPSAhcGlubmVkVUk7CiAgICAg
ICAgZS5jdXJyZW50VGFyZ2V0LmNsYXNzTGlzdC50b2dnbGUoJ29uJywgcGlubmVkVUkpOwogICAg
ICAgIGFoaygndG9nZ2xlUGluJywgcGlubmVkVUkgPyAnMScgOiAnMCcpOwogICAgfSk7CgogICAg
d2luZG93Ll9fdXBkYXRlQ2xpcHMgPSBwYXlsb2FkID0+IHsKICAgICAgICAvLyBLZWVwIHByZXZp
b3VzIHNjcm9sbCBmb3IgbG9hZC1tb3JlOyByZXNldCB3aGVuIG9wZW5pbmcgcGFuZWwgdG8gZmly
c3QgaXRlbQogICAgICAgIGNvbnN0IGtlZXBTY3JvbGwgPSAhc2VsZWN0Rmlyc3RPblNob3c7CiAg
ICAgICAgY29uc3Qgc3QgPSBsaXN0RWwuc2Nyb2xsVG9wOwogICAgICAgIC8vIOaVsOaNruWIsOS6
hu+8jOWPlua2iCBzZXRUYWIg5o6S6Zif55qE44CM5bu26L+f6aqo5p6244CNdGltZXLvvIjpgb/l
hY3lroPliLDngrnlkI7lj4jlvIAgc2tlbGV0b27vvIkKICAgICAgICBpZiAod2luZG93Ll9fcGVu
ZGluZ1NrZWxUaW1lcikgewogICAgICAgICAgICBjbGVhclRpbWVvdXQod2luZG93Ll9fcGVuZGlu
Z1NrZWxUaW1lcik7CiAgICAgICAgICAgIHdpbmRvdy5fX3BlbmRpbmdTa2VsVGltZXIgPSAwOwog
ICAgICAgIH0KICAgICAgICB3aW5kb3cuX19wZW5kaW5nU2tlbFNpbmNlID0gMDsKICAgICAgICAv
LyDph43nva4gbG9hZGluZ01vcmUg54q25oCBCiAgICAgICAgY29uc3Qgd2FzQXBwZW5kID0gcGF5
bG9hZCAmJiBwYXlsb2FkLmFwcGVuZDsKICAgICAgICBsb2FkaW5nTW9yZSA9IGZhbHNlOwogICAg
ICAgIGlmIChBcnJheS5pc0FycmF5KHBheWxvYWQpKSB7CiAgICAgICAgICAgIGFsbENsaXBzID0g
cGF5bG9hZDsKICAgICAgICAgICAgZGlza1RvdGFsID0gcGF5bG9hZC5sZW5ndGg7CiAgICAgICAg
fSBlbHNlIGlmIChwYXlsb2FkICYmIHR5cGVvZiBwYXlsb2FkID09PSAnb2JqZWN0JykgewogICAg
ICAgICAgICBkaXNrVG90YWwgPSBOdW1iZXIocGF5bG9hZC50b3RhbCkgfHwgMDsKICAgICAgICAg
ICAgY29uc3QgaXRlbXMgPSBBcnJheS5pc0FycmF5KHBheWxvYWQuaXRlbXMpID8gcGF5bG9hZC5p
dGVtcyA6IFtdOwogICAgICAgICAgICBpZiAocGF5bG9hZC5hcHBlbmQpIHsKICAgICAgICAgICAg
ICAgIGNvbnN0IHNlZW4gPSBuZXcgU2V0KGFsbENsaXBzLm1hcChjID0+ICtjLmlkKSk7CiAgICAg
ICAgICAgICAgICBpdGVtcy5mb3JFYWNoKGl0ID0+IHsKICAgICAgICAgICAgICAgICAgICBpZiAo
IXNlZW4uaGFzKCtpdC5pZCkpIGFsbENsaXBzLnB1c2goaXQpOwogICAgICAgICAgICAgICAgfSk7
CiAgICAgICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgICAgICBhbGxDbGlwcyA9IGl0ZW1zOwog
ICAgICAgICAgICB9CiAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgYWxsQ2xpcHMgPSBbXTsK
ICAgICAgICAgICAgZGlza1RvdGFsID0gMDsKICAgICAgICB9CiAgICAgICAgd2luZG93Ll9fZGF0
YVJlYWR5ID0gdHJ1ZTsKICAgICAgICBjb25zdCB3YXNCb290TG9hZGluZyA9IGJvb3RMb2FkaW5n
OwogICAgICAgIGNvbnN0IGZpbmlzaFVwZGF0ZSA9ICgpID0+IHsKICAgICAgICAgICAgc2V0Qm9v
dExvYWRpbmcoZmFsc2UpOwogICAgICAgICAgICByZW5kZXIoKTsKICAgICAgICAgICAgYXBwbHlU
YWJTd2l0Y2hBbmltKCk7CiAgICAgICAgICAgIGlmIChrZWVwU2Nyb2xsKQogICAgICAgICAgICAg
ICAgbGlzdEVsLnNjcm9sbFRvcCA9IHN0OwogICAgICAgICAgICBlbHNlCiAgICAgICAgICAgICAg
ICBsaXN0RWwuc2Nyb2xsVG9wID0gMDsKICAgICAgICB9OwogICAgICAgIGlmICh3YXNCb290TG9h
ZGluZykgewogICAgICAgICAgICBjb25zdCBpc1RhYlN3aXRjaCA9IHRhYlN3aXRjaEFuaW1EaXIg
IT09IDA7CiAgICAgICAgICAgIGNvbnN0IHNrZWxNaW4gPSBpc1RhYlN3aXRjaCA/IDE0MCA6IDM2
MDsKICAgICAgICAgICAgY29uc3Qgc2luY2UgPSB3aW5kb3cuX19za2VsU2luY2UgfHwgMDsKICAg
ICAgICAgICAgY29uc3Qgd2FpdCA9IHNpbmNlID8gTWF0aC5tYXgoMCwgc2tlbE1pbiAtIChEYXRl
Lm5vdygpIC0gc2luY2UpKSA6IDA7CiAgICAgICAgICAgIGlmICh3YWl0ID4gMCkKICAgICAgICAg
ICAgICAgIHNldFRpbWVvdXQoZmluaXNoVXBkYXRlLCB3YWl0KTsKICAgICAgICAgICAgZWxzZQog
ICAgICAgICAgICAgICAgZmluaXNoVXBkYXRlKCk7CiAgICAgICAgfSBlbHNlIHsKICAgICAgICAg
ICAgZmluaXNoVXBkYXRlKCk7CiAgICAgICAgfQogICAgfTsKICAgIHdpbmRvdy5fX3NldFBpbm5l
ZCA9IHYgPT4gewogICAgICAgIHBpbm5lZFVJID0gISF2OwogICAgICAgIGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCdidG4tcGluJykuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCBwaW5uZWRVSSk7CiAg
ICB9OwogICAgd2luZG93Ll9fbG9hZE1vcmVEb25lID0gKCkgPT4gewogICAgICAgIGxvYWRpbmdN
b3JlID0gZmFsc2U7CiAgICB9OwoKICAgIHJlcXVlc3RWaWV3KCk7CiAgICByZW5kZXIoKTsKCiAg
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
