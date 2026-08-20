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
    ; preferUIA is unused for OneNote now —callers skipHeavy instead (UIA crashes OneNote)
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
bmRlZCB7CiAgICAgICAgICAgIG1heC1oZWlnaHQ6IG5vbmU7CiAgICAgICAgICAgIG92ZXJmbG93OiB2
aXNpYmxlOwogICAgICAgIH0KICAgICAgICAuaS1leHBhbmQtYnRuLCAuaS1tZXRhIHsgdXNlci1zZWxl
Y3Q6IG5vbmU7IH0KICAgICAgICAjc2VhcmNoOjpwbGFjZWhvbGRlciB7IGNvbG9yOiB2YXIoLS10eHQz
KTsgfQogICAgICAgICNzZWFyY2gtY2xyIHsKICAgICAgICAgICAgcG9zaXRpb246IGFic29sdXRlOyBy
aWdodDogNHB4OyB0b3A6IDUwJTsgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKC01MCUpOwogICAgICAgICAg
ICBib3JkZXI6IG5vbmU7IGJhY2tncm91bmQ6IG5vbmU7IGNvbG9yOiB2YXIoLS10eHQzKTsgY3Vyc29y
OiBwb2ludGVyOwogICAgICAgICAgICBmb250LXNpemU6IDExcHg7IGRpc3BsYXk6IG5vbmU7IHBhZGRp
bmc6IDJweDsKICAgICAgICAgICAgb3BhY2l0eTogMC44NTsKICAgICAgICAgICAgdHJhbnNpdGlvbjog
Y29sb3IgMC4xMnMgZWFzZSwgb3BhY2l0eSAwLjEycyBlYXNlOwogICAgICAgICAgICAtd2Via2l0LWFw
cC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgfQogICAgICAgICNz
ZWFyY2gtY2xyOmhvdmVyIHsgY29sb3I6IHZhcigtLWFjYyk7IG9wYWNpdHk6IDE7IH0KCiAgICAgICAg
I2J0bi10b2RheSB7CiAgICAgICAgICAgIGRpc3BsYXk6IG5vbmU7CiAgICAgICAgICAgIGhlaWdodDog
MThweDsgcGFkZGluZzogMCA3cHg7IGZsZXgtc2hyaW5rOiAwOwogICAgICAgICAgICBhbGlnbi1pdGVt
czogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAgICAgICAgICAgYm9yZGVyOiAxcHgg
c29saWQgcmdiYSg5MSwxMTUsMjMyLC4yMik7IGJhY2tncm91bmQ6IHJnYmEoOTEsMTE1LDIzMiwuMTAp
OwogICAgICAgICAgICBjb2xvcjogIzZiODJlODsgYm9yZGVyLXJhZGl1czogOTk5cHg7IGZvbnQtc2l6
ZTogOXB4OyBmb250LXdlaWdodDogNjAwOwogICAgICAgICAgICBsaW5lLWhlaWdodDogMTsgd2hpdGUt
c3BhY2U6IG5vd3JhcDsgY3Vyc29yOiBwb2ludGVyOwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdp
b246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgICAgIHRyYW5zaXRpb246IGNv
bG9yIHZhcigtLXRyKSwgYmFja2dyb3VuZCB2YXIoLS10ciksIGJvcmRlci1jb2xvciB2YXIoLS10ciks
IG9wYWNpdHkgdmFyKC0tdHIpOwogICAgICAgIH0KICAgICAgICAjc2VhcmNoLXdyYXAub3BlbiAjYnRu
LXRvZGF5IHsgZGlzcGxheTogaW5saW5lLWZsZXg7IH0KICAgICAgICAjYnRuLXRvZGF5OmhvdmVyIHsg
Y29sb3I6ICM0YTYyZDQ7IGJhY2tncm91bmQ6IHJnYmEoOTEsMTE1LDIzMiwuMTYpOyB9CiAgICAgICAg
I2J0bi10b2RheS5vbiB7CiAgICAgICAgICAgIGNvbG9yOiAjNWI3M2U4OwogICAgICAgICAgICBiYWNr
Z3JvdW5kOiByZ2JhKDkxLDExNSwyMzIsLjE2KTsKICAgICAgICAgICAgYm9yZGVyLWNvbG9yOiByZ2Jh
KDkxLDExNSwyMzIsLjMyKTsKICAgICAgICB9CiAgICAgICAgI2J0bi10b2RheTpub3QoLm9uKSB7CiAg
ICAgICAgICAgIGNvbG9yOiB2YXIoLS10eHQzKTsKICAgICAgICAgICAgYmFja2dyb3VuZDogcmdiYSgw
LDAsMCwuMDQpOwogICAgICAgICAgICBib3JkZXItY29sb3I6IHJnYmEoMCwwLDAsLjA2KTsKICAgICAg
ICB9CgogICAgICAgICNidG4tcGluIHsKICAgICAgICAgICAgd2lkdGg6IDI4cHg7IGhlaWdodDogMjhw
eDsgZmxleC1zaHJpbms6IDA7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBj
ZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwogICAgICAgICAgICBib3JkZXI6IDEuNXB4IHNv
bGlkIHRyYW5zcGFyZW50OyBiYWNrZ3JvdW5kOiBub25lOyBjdXJzb3I6IHBvaW50ZXI7CiAgICAgICAg
ICAgIGNvbG9yOiB2YXIoLS10eHQzKTsgYm9yZGVyLXJhZGl1czogdmFyKC0tcik7CiAgICAgICAgICAg
IC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICAg
ICAgdHJhbnNpdGlvbjogY29sb3IgdmFyKC0tdHIpLCBiYWNrZ3JvdW5kIHZhcigtLXRyKSwgYm9yZGVy
LWNvbG9yIHZhcigtLXRyKTsKICAgICAgICB9CiAgICAgICAgI2J0bi1waW46aG92ZXIgeyBjb2xvcjog
dmFyKC0tYWNjKTsgYmFja2dyb3VuZDogcmdiYSg5MSwxMTUsMjMyLC4xKTsgfQogICAgICAgICNidG4t
cGluLm9uICB7CiAgICAgICAgICAgIGNvbG9yOiB2YXIoLS1hY2MpOwogICAgICAgICAgICBiYWNrZ3Jv
dW5kOiByZ2JhKDkxLDExNSwyMzIsLjE4KTsKICAgICAgICAgICAgYm9yZGVyLWNvbG9yOiByZ2JhKDkx
LDExNSwyMzIsLjU1KTsKICAgICAgICB9CiAgICAgICAgI2J0bi1waW4gc3ZnIHsgd2lkdGg6IDE0cHg7
IGhlaWdodDogMTRweDsgZGlzcGxheTogYmxvY2s7IH0KCiAgICAgICAgI2J0bi1sb2NhdGUgewogICAg
ICAgICAgICB3aWR0aDogMjhweDsgaGVpZ2h0OiAyOHB4OyBmbGV4LXNocmluazogMDsKICAgICAgICAg
ICAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50
ZXI7CiAgICAgICAgICAgIGJvcmRlcjogbm9uZTsgYmFja2dyb3VuZDogbm9uZTsgY3Vyc29yOiBwb2lu
dGVyOwogICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0Myk7IGJvcmRlci1yYWRpdXM6IHZhcigtLXIp
OwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRy
YWc7CiAgICAgICAgICAgIHRyYW5zaXRpb246IGNvbG9yIHZhcigtLXRyKSwgYmFja2dyb3VuZCB2YXIo
LS10ciksIG9wYWNpdHkgdmFyKC0tdHIpOwogICAgICAgIH0KICAgICAgICAjYnRuLWxvY2F0ZTpob3Zl
cjpub3QoOmRpc2FibGVkKSB7IGNvbG9yOiB2YXIoLS1hY2MpOyBiYWNrZ3JvdW5kOiByZ2JhKDkxLDEx
NSwyMzIsLjEpOyB9CiAgICAgICAgI2J0bi1sb2NhdGU6ZGlzYWJsZWQgeyBvcGFjaXR5OiAuMzU7IGN1
cnNvcjogZGVmYXVsdDsgfQogICAgICAgICNidG4tbG9jYXRlLmhhcy10YXJnZXQgeyBjb2xvcjogdmFy
KC0tYWNjKTsgfQogICAgICAgICNidG4tbG9jYXRlLm9uIHsKICAgICAgICAgICAgY29sb3I6IHZhcigt
LWFjYyk7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoOTEsMTE1LDIzMiwuMTgpOwogICAgICAg
IH0KICAgICAgICAjYnRuLWxvY2F0ZSBzdmcgeyB3aWR0aDogMTVweDsgaGVpZ2h0OiAxNXB4OyBkaXNw
bGF5OiBibG9jazsgfQogICAgICAgICNoZHI6aGFzKCNzZWFyY2gtd3JhcC5vcGVuKSAjYnRuLWxvY2F0
ZSB7CiAgICAgICAgICAgIGRpc3BsYXk6IG5vbmU7CiAgICAgICAgfQoKICAgICAgICAvKiDilIDilIAg
Um93IDIg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSAICovCiAgICAgICAgI3RhYnMgewogICAgICAgICAgICBwb3NpdGlvbjogcmVsYXRpdmU7CiAgICAg
ICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogMnB4OyBmbGV4LXdy
YXA6IG5vd3JhcDsKICAgICAgICAgICAgcGFkZGluZzogNXB4IDZweCA1cHggOHB4OyBmbGV4LXNocmlu
azogMDsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2YyZjRmOTsKICAgICAgICB9CiAgICAgICAgI3Rh
Yi1pbmsgewogICAgICAgICAgICBwb3NpdGlvbjogYWJzb2x1dGU7CiAgICAgICAgICAgIGxlZnQ6IDA7
IHRvcDogMDsKICAgICAgICAgICAgaGVpZ2h0OiAyMnB4OwogICAgICAgICAgICBib3JkZXItcmFkaXVz
OiA5OTlweDsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2ZmZjsKICAgICAgICAgICAgYm94LXNoYWRv
dzogMCAxcHggM3B4IHJnYmEoMCwwLDAsLjA3KSwgMCAwIDAgMXB4IHJnYmEoOTEsMTE1LDIzMiwuMDYp
OwogICAgICAgICAgICBwb2ludGVyLWV2ZW50czogbm9uZTsKICAgICAgICAgICAgei1pbmRleDogMDsK
ICAgICAgICAgICAgdHJhbnNmb3JtOiB0cmFuc2xhdGUzZCgwLDAsMCkgc2NhbGVYKDEpOwogICAgICAg
ICAgICB0cmFuc2Zvcm0tb3JpZ2luOiBjZW50ZXIgYm90dG9tOwogICAgICAgICAgICB0cmFuc2l0aW9u
OgogICAgICAgICAgICAgICAgdHJhbnNmb3JtIDAuMzRzIGN1YmljLWJlemllcigwLjIyLCAxLjE4LCAw
LjMyLCAxKSwKICAgICAgICAgICAgICAgIGhlaWdodCAwLjI0cyBlYXNlOwogICAgICAgICAgICB3aWxs
LWNoYW5nZTogdHJhbnNmb3JtLCBoZWlnaHQ7CiAgICAgICAgfQogICAgICAgICN0YWItaW5rLnNxdWFz
aCB7CiAgICAgICAgICAgIHRyYW5zaXRpb246CiAgICAgICAgICAgICAgICB0cmFuc2Zvcm0gMC4zMHMg
Y3ViaWMtYmV6aWVyKDAuMzQsIDEuMjgsIDAuNDQsIDEpLAogICAgICAgICAgICAgICAgaGVpZ2h0IDAu
MjBzIGVhc2U7CiAgICAgICAgfQogICAgICAgIC50YWIgewogICAgICAgICAgICBwb3NpdGlvbjogcmVs
YXRpdmU7CiAgICAgICAgICAgIHotaW5kZXg6IDE7CiAgICAgICAgICAgIHBhZGRpbmc6IDNweCAxMHB4
OyBmb250LXNpemU6IDExcHg7IGNvbG9yOiB2YXIoLS10eHQyKTsgY3Vyc29yOiBwb2ludGVyOwogICAg
ICAgICAgICBib3JkZXItcmFkaXVzOiA5OTlweDsgd2hpdGUtc3BhY2U6IG5vd3JhcDsKICAgICAgICAg
ICAgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7CiAgICAgICAgICAgIHRyYW5zaXRpb246IGNvbG9yIDAu
MjhzIGN1YmljLWJlemllcigwLjIyLCAxLCAwLjM2LCAxKSwKICAgICAgICAgICAgICAgICAgICAgICAg
dHJhbnNmb3JtIDAuMjhzIGN1YmljLWJlemllcigwLjIyLCAxLCAwLjM2LCAxKTsKICAgICAgICAgICAg
LXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgIH0K
ICAgICAgICAudGFiOmhvdmVyIHsgY29sb3I6IHZhcigtLXR4dCk7IGJhY2tncm91bmQ6IHRyYW5zcGFy
ZW50OyB9CiAgICAgICAgLnRhYjphY3RpdmUgeyB0cmFuc2Zvcm06IHNjYWxlKDAuOTYpOyB9CiAgICAg
ICAgLnRhYi5vbiB7IGNvbG9yOiB2YXIoLS1hY2MpOyBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsgYm94
LXNoYWRvdzogbm9uZTsgZm9udC13ZWlnaHQ6IDYwMDsgfQogICAgICAgIC5iYWRnZSB7CiAgICAgICAg
ICAgIGRpc3BsYXk6IGlubGluZS1mbGV4OyBtaW4td2lkdGg6IDE0cHg7IGhlaWdodDogMTRweDsgcGFk
ZGluZzogMCAzcHg7CiAgICAgICAgICAgIGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVu
dDogY2VudGVyOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiB2YXIoLS1hY2MpOyBjb2xvcjogI2ZmZjsg
Zm9udC1zaXplOiA5cHg7IGJvcmRlci1yYWRpdXM6IDdweDsgZm9udC13ZWlnaHQ6IDcwMDsKICAgICAg
ICB9CiAgICAgICAgI3RhYi1hY3Rpb25zIHsKICAgICAgICAgICAgbWFyZ2luLWxlZnQ6IGF1dG87IGRp
c3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogNHB4OwogICAgICAgICAgICBjb2xv
cjogdmFyKC0tdHh0Myk7IGZvbnQtc2l6ZTogMTBweDsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVn
aW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgIH0KICAgICAgICAjYmFyLXR4
dCB7IHdoaXRlLXNwYWNlOiBub3dyYXA7IH0KICAgICAgICAjYnRuLWNsciB7CiAgICAgICAgICAgIGRp
c3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwog
ICAgICAgICAgICB3aWR0aDogMjZweDsgaGVpZ2h0OiAyNnB4OyBib3JkZXI6IG5vbmU7IGJhY2tncm91
bmQ6IG5vbmU7IGNvbG9yOiB2YXIoLS10eHQzKTsKICAgICAgICAgICAgY3Vyc29yOiBwb2ludGVyOyBi
b3JkZXItcmFkaXVzOiB2YXIoLS1yKTsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1k
cmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgICAgICB0cmFuc2l0aW9uOiBjb2xvciB2YXIo
LS10ciksIGJhY2tncm91bmQgdmFyKC0tdHIpOwogICAgICAgIH0KICAgICAgICAjYnRuLWNscjpob3Zl
ciB7IGNvbG9yOiAjZmY3YjljOyBiYWNrZ3JvdW5kOiByZ2JhKDI1NSwxMjMsMTU2LC4wOCk7IH0KICAg
ICAgICAjYnRuLWNsciBzdmcgeyB3aWR0aDogMTRweDsgaGVpZ2h0OiAxNHB4OyBkaXNwbGF5OiBibG9j
azsgfQoKICAgICAgICAvKiDilIDilIAgTGlzdCDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIAgKi8KICAgICAgICAjbGlzdCB7CiAgICAgICAgICAg
IGZsZXg6IDE7IG92ZXJmbG93LXk6IGF1dG87IG92ZXJmbG93LXg6IGhpZGRlbjsgcGFkZGluZzogNnB4
IDhweCA2cHggMTBweDsgY3Vyc29yOiBkZWZhdWx0OwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdp
b246IGRyYWc7IGFwcC1yZWdpb246IGRyYWc7CiAgICAgICAgICAgIG1pbi1oZWlnaHQ6IDA7CiAgICAg
ICAgfQogICAgICAgIEBrZXlmcmFtZXMgdGFiUGFuZUluTHIgewogICAgICAgICAgICBmcm9tIHsgb3Bh
Y2l0eTogMDsgdHJhbnNmb3JtOiB0cmFuc2xhdGVYKC00MHB4KTsgfQogICAgICAgICAgICB0byB7IG9w
YWNpdHk6IDE7IHRyYW5zZm9ybTogdHJhbnNsYXRlWCgwKTsgfQogICAgICAgIH0KICAgICAgICBAa2V5
ZnJhbWVzIHRhYlBhbmVJblJsIHsKICAgICAgICAgICAgZnJvbSB7IG9wYWNpdHk6IDA7IHRyYW5zZm9y
bTogdHJhbnNsYXRlWCg0MHB4KTsgfQogICAgICAgICAgICB0byB7IG9wYWNpdHk6IDE7IHRyYW5zZm9y
bTogdHJhbnNsYXRlWCgwKTsgfQogICAgICAgIH0KICAgICAgICAjbGlzdC50YWItaW4tbHIgeyBhbmlt
YXRpb246IHRhYlBhbmVJbkxyIC4zNHMgY3ViaWMtYmV6aWVyKC4yMiwgMSwgLjM2LCAxKSBib3RoOyB9
CiAgICAgICAgI2xpc3QudGFiLWluLXJsIHsgYW5pbWF0aW9uOiB0YWJQYW5lSW5SbCAuMzRzIGN1Ymlj
LWJlemllciguMjIsIDEsIC4zNiwgMSkgYm90aDsgfQogICAgICAgICNidG4tdG9wIHsKICAgICAgICAg
ICAgcG9zaXRpb246IGFic29sdXRlOyByaWdodDogMTBweDsgYm90dG9tOiAxMHB4OyB6LWluZGV4OiAy
MDsKICAgICAgICAgICAgd2lkdGg6IDI4cHg7IGhlaWdodDogMjhweDsgYm9yZGVyOiBub25lOyBib3Jk
ZXItcmFkaXVzOiA1MCU7CiAgICAgICAgICAgIGRpc3BsYXk6IG5vbmU7IGFsaWduLWl0ZW1zOiBjZW50
ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZmZmOyBj
b2xvcjogdmFyKC0tdHh0Mik7CiAgICAgICAgICAgIGJveC1zaGFkb3c6IDAgMnB4IDhweCByZ2JhKDI0
LDMyLDU2LC4xNik7CiAgICAgICAgICAgIGN1cnNvcjogcG9pbnRlcjsKICAgICAgICAgICAgLXdlYmtp
dC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgICAgICB0cmFu
c2l0aW9uOiBiYWNrZ3JvdW5kIHZhcigtLXRyKSwgY29sb3IgdmFyKC0tdHIpLCBib3gtc2hhZG93IHZh
cigtLXRyKTsKICAgICAgICB9CiAgICAgICAgI2J0bi10b3Aub24geyBkaXNwbGF5OiBmbGV4OyB9CiAg
ICAgICAgI2J0bi10b3A6aG92ZXIgeyBjb2xvcjogdmFyKC0tYWNjKTsgYmFja2dyb3VuZDogI2VkZjFm
ZjsgYm94LXNoYWRvdzogMCAzcHggMTBweCByZ2JhKDkxLDExNSwyMzIsLjI1KTsgfQogICAgICAgICNi
dG4tdG9wIHN2ZyB7IHdpZHRoOiAxNHB4OyBoZWlnaHQ6IDE0cHg7IGRpc3BsYXk6IGJsb2NrOyB9CiAg
ICAgICAgI2VtcHR5IHsKICAgICAgICAgICAgZGlzcGxheTogbm9uZTsgZmxleC1kaXJlY3Rpb246IGNv
bHVtbjsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7CiAgICAgICAg
ICAgIHBhZGRpbmc6IDQ4cHggMTZweDsgY29sb3I6IHZhcigtLXR4dDMpOyBnYXA6IDhweDsKICAgICAg
ICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBkcmFnOyBhcHAtcmVnaW9uOiBkcmFnOwogICAgICAgIH0K
ICAgICAgICAjZW1wdHkub24geyBkaXNwbGF5OiBmbGV4OyB9CiAgICAgICAgLmUtdHh0IHsgZm9udC1z
aXplOiAxMnB4OyB0ZXh0LWFsaWduOiBjZW50ZXI7IGxldHRlci1zcGFjaW5nOiAuMDJlbTsgfQogICAg
ICAgICNza2VsIHsKICAgICAgICAgICAgZGlzcGxheTogbm9uZTsgZmxleC1kaXJlY3Rpb246IGNvbHVt
bjsgZ2FwOiA4cHg7CiAgICAgICAgICAgIHBhZGRpbmc6IDRweCAycHggMTBweDsgLXdlYmtpdC1hcHAt
cmVnaW9uOiBkcmFnOyBhcHAtcmVnaW9uOiBkcmFnOwogICAgICAgIH0KICAgICAgICAjc2tlbC5vbiB7
IGRpc3BsYXk6IGZsZXg7IH0KICAgICAgICAjYXBwLmJvb3QtbG9hZGluZyAjc2tlbCB7CiAgICAgICAg
ICAgIGRpc3BsYXk6IGZsZXggIWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgI2FwcC5ib290LWxv
YWRpbmcgI2VtcHR5IHsKICAgICAgICAgICAgZGlzcGxheTogbm9uZSAhaW1wb3J0YW50OwogICAgICAg
IH0KICAgICAgICAuc2stcm93IHsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6
IGZsZXgtc3RhcnQ7IGdhcDogMTBweDsKICAgICAgICAgICAgcGFkZGluZzogMTBweCA4cHg7IGJvcmRl
ci1yYWRpdXM6IDhweDsKICAgICAgICAgICAgYmFja2dyb3VuZDogcmdiYSgyNTUsMjU1LDI1NSwuNzIp
OwogICAgICAgICAgICBib3JkZXI6IDFweCBzb2xpZCByZ2JhKDE3MCwxODAsMjAwLC40NSk7CiAgICAg
ICAgICAgIHBvc2l0aW9uOiByZWxhdGl2ZTsKICAgICAgICAgICAgb3ZlcmZsb3c6IGhpZGRlbjsKICAg
ICAgICB9CiAgICAgICAgLnNrLXJvdzo6YWZ0ZXIgewogICAgICAgICAgICBjb250ZW50OiAnJzsKICAg
ICAgICAgICAgcG9zaXRpb246IGFic29sdXRlOwogICAgICAgICAgICBpbnNldDogMDsKICAgICAgICAg
ICAgYmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50KDkwZGVnLCB0cmFuc3BhcmVudCAwJSwgcmdiYSgy
NTUsMjU1LDI1NSwuNzIpIDQ4JSwgdHJhbnNwYXJlbnQgMTAwJSk7CiAgICAgICAgICAgIHRyYW5zZm9y
bTogdHJhbnNsYXRlWCgtMTIwJSk7CiAgICAgICAgICAgIGFuaW1hdGlvbjogc2stc3dlZXAgMC45NXMg
ZWFzZS1pbi1vdXQgaW5maW5pdGU7CiAgICAgICAgICAgIHBvaW50ZXItZXZlbnRzOiBub25lOwogICAg
ICAgIH0KICAgICAgICBAa2V5ZnJhbWVzIHNrLXN3ZWVwIHsKICAgICAgICAgICAgMTAwJSB7IHRyYW5z
Zm9ybTogdHJhbnNsYXRlWCgxMjAlKTsgfQogICAgICAgIH0KICAgICAgICAuc2staWNvLCAuc2stbGlu
ZSB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IGxpbmVhci1ncmFkaWVudCg5MGRlZywgI2I4YzJkOCAw
JSwgI2YwZjRmYSAzOCUsICNkY2UzZjAgNTIlLCAjYjhjMmQ4IDEwMCUpOwogICAgICAgICAgICBiYWNr
Z3JvdW5kLXNpemU6IDI0MCUgMTAwJTsKICAgICAgICAgICAgYW5pbWF0aW9uOiBzay1zaGltbWVyIDAu
NzJzIGVhc2UtaW4tb3V0IGluZmluaXRlOwogICAgICAgICAgICB3aWxsLWNoYW5nZTogYmFja2dyb3Vu
ZC1wb3NpdGlvbjsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogNnB4OwogICAgICAgIH0KICAgICAg
ICAuc2staWNvIHsgd2lkdGg6IDM0cHg7IGhlaWdodDogMzRweDsgZmxleC1zaHJpbms6IDA7IGJvcmRl
ci1yYWRpdXM6IDhweDsgfQogICAgICAgIC5zay1ib2R5IHsgZmxleDogMTsgbWluLXdpZHRoOiAwOyBk
aXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBnYXA6IDhweDsgcGFkZGluZy10b3A6
IDJweDsgfQogICAgICAgIC5zay1saW5lIHsgaGVpZ2h0OiAxMHB4OyB3aWR0aDogMTAwJTsgfQogICAg
ICAgIC5zay1saW5lLnNob3J0IHsgd2lkdGg6IDQyJTsgfQogICAgICAgIC5zay1saW5lLm1pZCB7IHdp
ZHRoOiA2OCU7IH0KICAgICAgICAuc2stcm93Om50aC1jaGlsZCgyKTo6YWZ0ZXIgeyBhbmltYXRpb24t
ZGVsYXk6IC4xMnM7IH0KICAgICAgICAuc2stcm93Om50aC1jaGlsZCgzKTo6YWZ0ZXIgeyBhbmltYXRp
b24tZGVsYXk6IC4yNHM7IH0KICAgICAgICAuc2stcm93Om50aC1jaGlsZCg0KTo6YWZ0ZXIgeyBhbmlt
YXRpb24tZGVsYXk6IC4zNnM7IH0KICAgICAgICAuc2stcm93Om50aC1jaGlsZCg1KTo6YWZ0ZXIgeyBh
bmltYXRpb24tZGVsYXk6IC40OHM7IH0KICAgICAgICAuc2stcm93Om50aC1jaGlsZCg2KTo6YWZ0ZXIg
eyBhbmltYXRpb24tZGVsYXk6IC42czsgfQogICAgICAgIEBrZXlmcmFtZXMgc2stc2hpbW1lciB7CiAg
ICAgICAgICAgIDAlIHsgYmFja2dyb3VuZC1wb3NpdGlvbjogMTAwJSAwOyB9CiAgICAgICAgICAgIDEw
MCUgeyBiYWNrZ3JvdW5kLXBvc2l0aW9uOiAtMTAwJSAwOyB9CiAgICAgICAgfQogICAgICAgIC5saXN0
LW1vcmUgewogICAgICAgICAgICB0ZXh0LWFsaWduOiBjZW50ZXI7IHBhZGRpbmc6IDEwcHggOHB4IDE0
cHg7IGZvbnQtc2l6ZTogMTFweDsKICAgICAgICAgICAgY29sb3I6IHZhcigtLXR4dDMpOyAtd2Via2l0
LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgfQogICAgICAg
IC5saXN0LW1vcmUuZG9uZSB7IGRpc3BsYXk6IG5vbmU7IH0KCiAgICAgICAgLml0bSB7CiAgICAgICAg
ICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBmbGV4LXN0YXJ0OyBnYXA6IDhweDsKICAgICAg
ICAgICAgcGFkZGluZzogOHB4OyBtYXJnaW4tYm90dG9tOiA1cHg7CiAgICAgICAgICAgIGJhY2tncm91
bmQ6IHZhcigtLWNhcmQpOyBib3JkZXItcmFkaXVzOiB2YXIoLS1yKTsgY3Vyc29yOiBwb2ludGVyOwog
ICAgICAgICAgICBib3gtc2hhZG93OiAwIDFweCAzcHggcmdiYSgyNCwzMiw1NiwuMDYpOwogICAgICAg
ICAgICAvKiBob3Zlci1saW5lICovCiAgICAgICAgICAgIHBvc2l0aW9uOiByZWxhdGl2ZTsKICAgICAg
ICAgICAgdHJhbnNpdGlvbjogYmFja2dyb3VuZCAuMnMgZWFzZSwgYm94LXNoYWRvdyAuMnMgZWFzZTsK
ICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFn
OwogICAgICAgICAgICBvdmVyZmxvdzogdmlzaWJsZTsKICAgICAgICB9CiAgICAgICAgLml0bTo6YmVm
b3JlIHsKICAgICAgICAgICAgY29udGVudDogIiI7CiAgICAgICAgICAgIHBvc2l0aW9uOiBhYnNvbHV0
ZTsKICAgICAgICAgICAgbGVmdDogMDsgcmlnaHQ6IDA7IGJvdHRvbTogMDsKICAgICAgICAgICAgaGVp
Z2h0OiAwOwogICAgICAgICAgICBwb2ludGVyLWV2ZW50czogbm9uZTsKICAgICAgICAgICAgei1pbmRl
eDogMDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogMCAwIHZhcigtLXIpIHZhcigtLXIpOwogICAg
ICAgICAgICBiYWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGllbnQodG8gdG9wLCByZ2JhKDkxLDExNSwyMzIs
LjMyKSwgcmdiYSg5MSwxMTUsMjMyLC4xMikgNTUlLCB0cmFuc3BhcmVudCk7CiAgICAgICAgICAgIHRy
YW5zaXRpb246IGhlaWdodCAuMzRzIGN1YmljLWJlemllciguMjIsMSwuMzYsMSk7CiAgICAgICAgfQog
ICAgICAgIC5pdG06aG92ZXI6OmJlZm9yZSB7IGhlaWdodDogMzMuMzMzJTsgfQogICAgICAgIC5pdG06
OmFmdGVyIHsKICAgICAgICAgICAgY29udGVudDogIiI7CiAgICAgICAgICAgIHBvc2l0aW9uOiBhYnNv
bHV0ZTsKICAgICAgICAgICAgbGVmdDogMDsgcmlnaHQ6IDA7IGJvdHRvbTogMDsKICAgICAgICAgICAg
aGVpZ2h0OiAycHg7CiAgICAgICAgICAgIHBvaW50ZXItZXZlbnRzOiBub25lOwogICAgICAgICAgICB6
LWluZGV4OiAxOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDkxLDExNSwyMzIsLjk1KTsKICAg
ICAgICAgICAgYm9yZGVyLXJhZGl1czogMXB4OwogICAgICAgICAgICB0cmFuc2Zvcm06IHNjYWxlWCgw
KTsKICAgICAgICAgICAgdHJhbnNmb3JtLW9yaWdpbjogY2VudGVyOwogICAgICAgICAgICB0cmFuc2l0
aW9uOiB0cmFuc2Zvcm0gLjNzIGN1YmljLWJlemllciguMjIsMSwuMzYsMSk7CiAgICAgICAgfQogICAg
ICAgIC5pdG06aG92ZXIgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiB2YXIoLS1jYXJkLWgpOwogICAg
ICAgICAgICBib3gtc2hhZG93OiAwIDJweCA4cHggcmdiYSgyNCwzMiw1NiwuMSk7CiAgICAgICAgfQog
ICAgICAgIC5pdG06aG92ZXI6OmFmdGVyIHsKICAgICAgICAgICAgdHJhbnNmb3JtOiBzY2FsZVgoMSk7
CiAgICAgICAgfQogICAgICAgIC5pdG0uc2VsIHsKICAgICAgICAgICAgYm94LXNoYWRvdzogMCAwIDAg
MnB4IHJnYmEoOTEsMTE1LDIzMiwuNDUpLCAwIDJweCA4cHggcmdiYSg5MSwxMTUsMjMyLC4xOCk7CiAg
ICAgICAgICAgIGJhY2tncm91bmQ6ICNlZGYxZmY7CiAgICAgICAgfQogICAgICAgIC5pdG0ubXVsdGkg
ewogICAgICAgICAgICBib3gtc2hhZG93OiAwIDAgMCAxLjVweCByZ2JhKDkxLDExNSwyMzIsLjU1KSwg
MCAycHggNnB4IHJnYmEoOTEsMTE1LDIzMiwuMTgpOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZWVm
MmZmOwogICAgICAgIH0KICAgICAgICAuaXRtLm11bHRpLnNlbCB7CiAgICAgICAgICAgIGJveC1zaGFk
b3c6IDAgMCAwIDJweCByZ2JhKDkxLDExNSwyMzIsLjcpLCAwIDJweCA4cHggcmdiYSg5MSwxMTUsMjMy
LC4yMik7CiAgICAgICAgfQoKICAgICAgICAjbXVsdGktY250IHsKICAgICAgICAgICAgZGlzcGxheTog
bm9uZTsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7CiAgICAgICAg
ICAgIGhlaWdodDogMjJweDsgcGFkZGluZzogMCA4cHg7IG1hcmdpbi1yaWdodDogNHB4OwogICAgICAg
ICAgICBib3JkZXI6IG5vbmU7IGJvcmRlci1yYWRpdXM6IDExcHg7IGN1cnNvcjogcG9pbnRlcjsKICAg
ICAgICAgICAgYmFja2dyb3VuZDogdmFyKC0tYWNjKTsgY29sb3I6ICNmZmY7IGZvbnQtc2l6ZTogMTFw
eDsgZm9udC13ZWlnaHQ6IDcwMDsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFn
OyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgICAgICB0cmFuc2l0aW9uOiBvcGFjaXR5IHZhcigt
LXRyKSwgYmFja2dyb3VuZCB2YXIoLS10cik7CiAgICAgICAgfQogICAgICAgICNtdWx0aS1jbnQ6aG92
ZXIgeyBiYWNrZ3JvdW5kOiAjNGE2MmQ0OyB9CiAgICAgICAgI211bHRpLWNudC5vbiB7IGRpc3BsYXk6
IGlubGluZS1mbGV4OyB9CgogICAgICAgIC5pLWljbyB7CiAgICAgICAgICAgIHdpZHRoOiAyOHB4OyBo
ZWlnaHQ6IDI4cHg7IGJvcmRlci1yYWRpdXM6IHZhcigtLXIpOyBkaXNwbGF5OiBmbGV4OwogICAgICAg
ICAgICBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsgZmxleC1zaHJp
bms6IDA7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNlZGYyZmY7IGNvbG9yOiB2YXIoLS1hY2MpOwog
ICAgICAgICAgICBwb3NpdGlvbjogcmVsYXRpdmU7IG92ZXJmbG93OiB2aXNpYmxlOwogICAgICAgIH0K
ICAgICAgICAuaS1pY28gc3ZnIHsgd2lkdGg6IDE2cHg7IGhlaWdodDogMTZweDsgZGlzcGxheTogYmxv
Y2s7IH0KICAgICAgICAuaS1pY28uZnQtaW1nIHsgY29sb3I6ICM3YWQ3ZmY7IH0KICAgICAgICAuaS1p
Y28uZnQtdmlkIHsgY29sb3I6ICNjMDg0ZmM7IH0KICAgICAgICAuaS1pY28uZnQtemlwIHsgY29sb3I6
ICM4YWI0ZmY7IH0KICAgICAgICAuaS1pY28uZnQtZGlyIHsgY29sb3I6ICNmZmQ1NmE7IH0KICAgICAg
ICAuaS1pY28uZnQtYWhrIHsgY29sb3I6ICM2ZGZmOWE7IH0KICAgICAgICAuaS1pY28ubWQgeyBjb2xv
cjogIzZiOGNmZjsgfQogICAgICAgIC5pLWljby5tZCBzdmcgeyB3aWR0aDogMjBweDsgaGVpZ2h0OiAy
MHB4OyB9CiAgICAgICAgLmktaWNvLmZ0LWxuaywgLmktaWNvLmZ0LWRvYyB7IGNvbG9yOiAjYTliZGQw
OyB9CiAgICAgICAgLmktdXNlZCB7CiAgICAgICAgICAgIHBvc2l0aW9uOiBhYnNvbHV0ZTsgcmlnaHQ6
IDA7IGJvdHRvbTogMDsKICAgICAgICAgICAgd2lkdGg6IDEzcHg7IGhlaWdodDogMTNweDsgYm9yZGVy
LXJhZGl1czogNTAlOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjMjJjNTVlOyBib3JkZXI6IDEuNXB4
IHNvbGlkICNmZmY7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7
IGp1c3RpZnktY29udGVudDogY2VudGVyOwogICAgICAgICAgICBwb2ludGVyLWV2ZW50czogbm9uZTsg
ei1pbmRleDogMzsKICAgICAgICAgICAgYm94LXNoYWRvdzogMCAxcHggMnB4IHJnYmEoMCwwLDAsLjE2
KTsKICAgICAgICAgICAgdHJhbnNmb3JtOiB0cmFuc2xhdGUoMzAlLCAzMCUpOwogICAgICAgIH0KICAg
ICAgICAuaS11c2VkIHN2ZyB7IHdpZHRoOiA5cHg7IGhlaWdodDogOXB4OyBjb2xvcjogI2ZmZjsgZGlz
cGxheTogYmxvY2s7IH0KCiAgICAgICAgLml0bS5qdW1wLWZsYXNoIHsKICAgICAgICAgICAgYm94LXNo
YWRvdzogMCAwIDAgMnB4IHJnYmEoOTEsMTE1LDIzMiwuNTUpLCAwIDJweCAxMHB4IHJnYmEoOTEsMTE1
LDIzMiwuMjIpOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZThlZGZmOwogICAgICAgICAgICB0cmFu
c2l0aW9uOiBiYWNrZ3JvdW5kIC4zNXMgZWFzZSwgYm94LXNoYWRvdyAuMzVzIGVhc2U7CiAgICAgICAg
fQoKICAgICAgICAuaS1ib2R5IHsgZmxleDogMTsgbWluLXdpZHRoOiAwOyBkaXNwbGF5OiBmbGV4OyBm
bGV4LWRpcmVjdGlvbjogY29sdW1uOyB9CiAgICAgICAgLmktcHJldiwgLmktbmFtZSB7CiAgICAgICAg
ICAgIGZvbnQtc2l6ZTogMTNweDsgZm9udC13ZWlnaHQ6IDUwMDsgY29sb3I6IHZhcigtLXR4dCk7IHdv
cmQtYnJlYWs6IGJyZWFrLWFsbDsKICAgICAgICAgICAgd2hpdGUtc3BhY2U6IHByZS13cmFwOyAvKiDm
lK/mjIHlpJrmlofku7Yv5aSa6KGM5paH5pys5o2i6KGM5pi+56S6ICovCiAgICAgICAgfQogICAgICAg
IC5pLXByZXYgewogICAgICAgICAgICBkaXNwbGF5OiAtd2Via2l0LWJveDsgLXdlYmtpdC1ib3gtb3Jp
ZW50OiB2ZXJ0aWNhbDsgLXdlYmtpdC1saW5lLWNsYW1wOiA1OyBvdmVyZmxvdzogaGlkZGVuOwogICAg
ICAgICAgICB0ZXh0LW92ZXJmbG93OiBlbGxpcHNpczsKICAgICAgICB9CiAgICAgICAgLmktbmFtZSB7
CiAgICAgICAgICAgIGRpc3BsYXk6IC13ZWJraXQtYm94OyAtd2Via2l0LWJveC1vcmllbnQ6IHZlcnRp
Y2FsOyAtd2Via2l0LWxpbmUtY2xhbXA6IDI7IG92ZXJmbG93OiBoaWRkZW47CiAgICAgICAgfQogICAg
ICAgIC8qIEZpbGUgY2xpcCB3aG9zZSBwYXRoKHMpIG5vIGxvbmdlciBleGlzdCDigJQgbGlnaHQgYm9s
ZCBncmF5IHN0cmlrZSAqLwogICAgICAgIC5pdG0uZ29uZSAuaS1uYW1lIHsKICAgICAgICAgICAgY29s
b3I6ICM5YWEwYjA7CiAgICAgICAgICAgIHRleHQtZGVjb3JhdGlvbjogbGluZS10aHJvdWdoOwogICAg
ICAgICAgICB0ZXh0LWRlY29yYXRpb24tdGhpY2tuZXNzOiAycHg7CiAgICAgICAgICAgIHRleHQtZGVj
b3JhdGlvbi1jb2xvcjogcmdiYSgxNTQsIDE2MCwgMTc2LCAuNTUpOwogICAgICAgICAgICB0ZXh0LWRl
Y29yYXRpb24tc2tpcC1pbms6IG5vbmU7CiAgICAgICAgfQogICAgICAgIC5pdG0uZ29uZSAuaS1pY28g
eyBvcGFjaXR5OiAuNTU7IH0KICAgICAgICAuaXRtLmdvbmUgLmktdGh1bWItd3JhcCB7IG9wYWNpdHk6
IC41NTsgfQogICAgICAgIC5pLXByZXYudXJsIHsgY29sb3I6IHZhcigtLWFjYyk7IH0KICAgICAgICAu
aS10aHVtYi13cmFwIHsKICAgICAgICAgICAgd2lkdGg6IDEwMCU7IG1pbi1oZWlnaHQ6IDQ4cHg7IG1h
eC1oZWlnaHQ6IDE4MHB4OyBtYXJnaW4tYm90dG9tOiA0cHg7CiAgICAgICAgICAgIGRpc3BsYXk6IGZs
ZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwogICAgICAgICAg
ICBiYWNrZ3JvdW5kOiAjZjNmNWY5OyBib3JkZXItcmFkaXVzOiB2YXIoLS1yKTsgb3ZlcmZsb3c6IGhp
ZGRlbjsKICAgICAgICB9CiAgICAgICAgLmktdGh1bWIgeyBtYXgtd2lkdGg6IDEwMCU7IG1heC1oZWln
aHQ6IDE4MHB4OyB3aWR0aDogYXV0bzsgaGVpZ2h0OiBhdXRvOyBvYmplY3QtZml0OiBjb250YWluOyBk
aXNwbGF5OiBibG9jazsgfQoKICAgICAgICAvKiBNZXRhIGJhcjogdGltZSBsZWZ0IHwgZXhwYW5kIGNl
bnRlciB8IHRhZ3MgcmlnaHQgKi8KICAgICAgICAuaS1tZXRhIHsKICAgICAgICAgICAgZGlzcGxheTog
Z3JpZDsKICAgICAgICAgICAgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiAxZnIgYXV0byAxZnI7CiAgICAg
ICAgICAgIGFsaWduLWl0ZW1zOiBjZW50ZXI7CiAgICAgICAgICAgIGdhcDogNHB4OwogICAgICAgICAg
ICBtYXJnaW4tdG9wOiA0cHg7CiAgICAgICAgICAgIHdpZHRoOiAxMDAlOwogICAgICAgIH0KICAgICAg
ICAuaS1tZXRhIC5pLXRpbWUgeyBqdXN0aWZ5LXNlbGY6IHN0YXJ0OyB9CiAgICAgICAgLmktbWV0YS1j
ZW50ZXIgewogICAgICAgICAgICBqdXN0aWZ5LXNlbGY6IGNlbnRlcjsKICAgICAgICAgICAgZGlzcGxh
eTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7CiAgICAg
ICAgICAgIGdhcDogNHB4OwogICAgICAgICAgICBtaW4td2lkdGg6IDFweDsgLyoga2VlcCBjZW50ZXIg
Y29sdW1uIGV2ZW4gd2hlbiBleHBhbmQgaXMgaGlkZGVuICovCiAgICAgICAgfQogICAgICAgIC5pLW1l
dGEtcmlnaHQgewogICAgICAgICAgICBqdXN0aWZ5LXNlbGY6IGVuZDsKICAgICAgICAgICAgZGlzcGxh
eTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA1cHg7IGZsZXgtd3JhcDogbm93cmFwOwog
ICAgICAgICAgICBqdXN0aWZ5LWNvbnRlbnQ6IGZsZXgtZW5kOwogICAgICAgICAgICBtaW4td2lkdGg6
IDA7CiAgICAgICAgfQogICAgICAgIC5pLW1ldGEtcmlnaHQudGV4dC1tZXRhIHsKICAgICAgICAgICAg
ZmxleC13cmFwOiBub3dyYXA7CiAgICAgICAgICAgIGdhcDogNHB4OwogICAgICAgIH0KICAgICAgICAu
aS1zcmMtdGl0bGUgewogICAgICAgICAgICBmb250LXNpemU6IDEwcHg7CiAgICAgICAgICAgIGNvbG9y
OiB2YXIoLS10eHQzKTsKICAgICAgICAgICAgbWF4LXdpZHRoOiAxMWVtOwogICAgICAgICAgICBvdmVy
ZmxvdzogaGlkZGVuOwogICAgICAgICAgICB0ZXh0LW92ZXJmbG93OiBlbGxpcHNpczsKICAgICAgICAg
ICAgd2hpdGUtc3BhY2U6IG5vd3JhcDsKICAgICAgICAgICAgbWluLXdpZHRoOiAwOwogICAgICAgICAg
ICBsaW5lLWhlaWdodDogMS40OwogICAgICAgIH0KICAgICAgICAuaS10aW1lLCAuaS10YWcgeyBmb250
LXNpemU6IDEwcHg7IGNvbG9yOiB2YXIoLS10eHQzKTsgfQogICAgICAgIC5pLXRhZyB7CiAgICAgICAg
ICAgIGJhY2tncm91bmQ6ICNmMWYzZjg7IHBhZGRpbmc6IDAgNXB4OyBib3JkZXItcmFkaXVzOiAzcHg7
CiAgICAgICAgICAgIHdoaXRlLXNwYWNlOiBub3dyYXA7IGZsZXgtc2hyaW5rOiAwOyBsaW5lLWhlaWdo
dDogMS40OwogICAgICAgIH0KICAgICAgICAuaS1jaGFycyB7CiAgICAgICAgICAgIGZvbnQtc2l6ZTog
MTBweDsgY29sb3I6IHZhcigtLXR4dDMpOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZjFmM2Y4OyBw
YWRkaW5nOiAwIDVweDsgYm9yZGVyLXJhZGl1czogM3B4OwogICAgICAgICAgICBmb250LXZhcmlhbnQt
bnVtZXJpYzogdGFidWxhci1udW1zOwogICAgICAgICAgICB3aGl0ZS1zcGFjZTogbm93cmFwOwogICAg
ICAgICAgICBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGJhc2VsaW5lOyBnYXA6IDJw
eDsKICAgICAgICB9CiAgICAgICAgLmktY2hhcnMgLm4gewogICAgICAgICAgICBkaXNwbGF5OiBpbmxp
bmUtYmxvY2s7CiAgICAgICAgICAgIG1pbi13aWR0aDogNGNoOwogICAgICAgICAgICB0ZXh0LWFsaWdu
OiByaWdodDsKICAgICAgICAgICAgZm9udC1mYW1pbHk6ICdDYXNjYWRpYSBNb25vJywgJ0NvbnNvbGFz
JywgJ1NhcmFzYSBNb25vIFNDJywgdWktbW9ub3NwYWNlLCBtb25vc3BhY2U7CiAgICAgICAgICAgIGZv
bnQtd2VpZ2h0OiA2MDA7CiAgICAgICAgICAgIGNvbG9yOiB2YXIoLS10eHQyKTsKICAgICAgICB9CiAg
ICAgICAgLyogc3JjLXRpdGxlLXRpcCAqLwogICAgICAgIC5pLXNyYy1pY28sIC5tZy1zcmMgeyBjdXJz
b3I6IHBvaW50ZXI7IH0KICAgICAgICAjc3JjLXRpcCB7CiAgICAgICAgICAgIHBvc2l0aW9uOiBmaXhl
ZDsgei1pbmRleDogOTk5OTk7CiAgICAgICAgICAgIG1heC13aWR0aDogbWluKDI4MHB4LCBjYWxjKDEw
MHZ3IC0gMTZweCkpOwogICAgICAgICAgICBwYWRkaW5nOiA2cHggMTBweDsKICAgICAgICAgICAgYm9y
ZGVyLXJhZGl1czogOHB4OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDMyLDM2LDQ4LC45Mik7
IGNvbG9yOiAjZmZmOwogICAgICAgICAgICBmb250LXNpemU6IDEycHg7IGxpbmUtaGVpZ2h0OiAxLjM1
OwogICAgICAgICAgICBib3gtc2hhZG93OiAwIDZweCAxOHB4IHJnYmEoMCwwLDAsLjIyKTsKICAgICAg
ICAgICAgcG9pbnRlci1ldmVudHM6IG5vbmU7CiAgICAgICAgICAgIG9wYWNpdHk6IDA7IHRyYW5zZm9y
bTogdHJhbnNsYXRlWSg0cHgpOwogICAgICAgICAgICB0cmFuc2l0aW9uOiBvcGFjaXR5IC4ycyBlYXNl
LCB0cmFuc2Zvcm0gLjIycyBjdWJpYy1iZXppZXIoLjIyLDEsLjM2LDEpOwogICAgICAgICAgICB3b3Jk
LWJyZWFrOiBicmVhay13b3JkOwogICAgICAgIH0KICAgICAgICAjc3JjLXRpcC5zaG93IHsgb3BhY2l0
eTogMTsgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKDApOyB9CiAgICAgICAgLmktc3JjLWljbyB7CiAgICAg
ICAgICAgIHdpZHRoOiAxNHB4OyBoZWlnaHQ6IDE0cHg7IGZsZXgtc2hyaW5rOiAwOwogICAgICAgICAg
ICBib3JkZXItcmFkaXVzOiAycHg7IG9iamVjdC1maXQ6IGNvbnRhaW47CiAgICAgICAgICAgIGRpc3Bs
YXk6IGJsb2NrOwogICAgICAgIH0KICAgICAgICAuaS1udW0gewogICAgICAgICAgICBkaXNwbGF5OiBm
bGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOyBhbGlnbi1pdGVtczogZmxleC1lbmQ7CiAgICAgICAg
ICAgIGp1c3RpZnktY29udGVudDogc3BhY2UtYmV0d2VlbjsKICAgICAgICAgICAgYWxpZ24tc2VsZjog
c3RyZXRjaDsKICAgICAgICAgICAgZm9udC1zaXplOiAxMHB4OyBjb2xvcjogdmFyKC0tdHh0Myk7IG1p
bi13aWR0aDogMTZweDsKICAgICAgICAgICAgdGV4dC1hbGlnbjogcmlnaHQ7IGZsZXgtc2hyaW5rOiAw
OwogICAgICAgICAgICBwYWRkaW5nLXRvcDogMnB4OwogICAgICAgIH0KICAgICAgICAuaS1udW0gLmkt
c3JjLWljbyB7IHdpZHRoOiAxNnB4OyBoZWlnaHQ6IDE2cHg7IG1hcmdpbi10b3A6IGF1dG87IH0KCiAg
ICAgICAgLmktZXhwYW5kLWJ0biB7CiAgICAgICAgICAgIGJvcmRlcjogbm9uZTsgYmFja2dyb3VuZDog
bm9uZTsgY3Vyc29yOiBwb2ludGVyOwogICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0Myk7IGZvbnQt
c2l6ZTogMTBweDsgcGFkZGluZzogMXB4IDZweDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogOHB4
OyBkaXNwbGF5OiBub25lOyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDJweDsKICAgICAgICAgICAg
dHJhbnNpdGlvbjogY29sb3IgdmFyKC0tdHIpLCBiYWNrZ3JvdW5kIHZhcigtLXRyKTsKICAgICAgICAg
ICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAg
IH0KICAgICAgICAuaS1leHBhbmQtYnRuLm9uIHsgZGlzcGxheTogaW5saW5lLWZsZXg7IH0KICAgICAg
ICAuaS1leHBhbmQtYnRuOmhvdmVyIHsgY29sb3I6IHZhcigtLWFjYyk7IGJhY2tncm91bmQ6IHJnYmEo
OTEsMTE1LDIzMiwuMDgpOyB9CiAgICAgICAgLmktcHJldi5leHBhbmRlZCwgLmktbmFtZS5leHBhbmRl
ZCB7CiAgICAgICAgICAgIC13ZWJraXQtbGluZS1jbGFtcDogdW5zZXQ7CiAgICAgICAgICAgIG92ZXJm
bG93OiB2aXNpYmxlOwogICAgICAgIH0KICAgICAgICAuaS1maWxlLWRldGFpbCB7CiAgICAgICAgICAg
IGRpc3BsYXk6IG5vbmU7CiAgICAgICAgICAgIG1hcmdpbi10b3A6IDRweDsKICAgICAgICAgICAgcGFk
ZGluZzogMDsKICAgICAgICAgICAgYmFja2dyb3VuZDogbm9uZTsKICAgICAgICAgICAgYm9yZGVyOiBu
b25lOwogICAgICAgIH0KICAgICAgICAuaS1maWxlLWRldGFpbC5vbiB7IGRpc3BsYXk6IGJsb2NrOyB9
CiAgICAgICAgLmZkLWJsb2NrIHsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rp
b246IGNvbHVtbjsgZ2FwOiA2cHg7CiAgICAgICAgfQogICAgICAgIC5mZC1ibG9jayArIC5mZC1ibG9j
ayB7IG1hcmdpbi10b3A6IDhweDsgfQogICAgICAgIC5mZC1wYXRoIHsKICAgICAgICAgICAgd2lkdGg6
IDEwMCU7CiAgICAgICAgICAgIGZvbnQ6IDYwMCAxMnB4LzEuNTUgJ1NlZ29lIFVJIFZhcmlhYmxlIFRl
eHQnLCdTZWdvZSBVSScsJ01pY3Jvc29mdCBZYUhlaSBVSScsc2Fucy1zZXJpZjsKICAgICAgICAgICAg
Y29sb3I6IHZhcigtLXR4dDIpOwogICAgICAgICAgICBsZXR0ZXItc3BhY2luZzogLjAxZW07CiAgICAg
ICAgICAgIHdvcmQtYnJlYWs6IGJyZWFrLWFsbDsKICAgICAgICAgICAgdXNlci1zZWxlY3Q6IHRleHQ7
CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJh
ZzsKICAgICAgICB9CiAgICAgICAgLmZkLXBhdGgubGl2ZSB7IGN1cnNvcjogcG9pbnRlcjsgfQogICAg
ICAgIC5mZC1wYXRoLmxpdmU6aG92ZXIgeyBjb2xvcjogdmFyKC0tYWNjKTsgfQogICAgICAgIC5mZC1w
YXRoLmRlYWQgewogICAgICAgICAgICBjb2xvcjogIzlhYTBiMDsKICAgICAgICAgICAgdGV4dC1kZWNv
cmF0aW9uOiBsaW5lLXRocm91Z2g7CiAgICAgICAgICAgIHRleHQtZGVjb3JhdGlvbi10aGlja25lc3M6
IDJweDsKICAgICAgICAgICAgdGV4dC1kZWNvcmF0aW9uLWNvbG9yOiByZ2JhKDE1NCwgMTYwLCAxNzYs
IC41NSk7CiAgICAgICAgICAgIHRleHQtZGVjb3JhdGlvbi1za2lwLWluazogbm9uZTsKICAgICAgICAg
ICAgY3Vyc29yOiBkZWZhdWx0OwogICAgICAgIH0KICAgICAgICAuZmQtYWN0aW9ucyB7CiAgICAgICAg
ICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogZmxl
eC1lbmQ7CiAgICAgICAgICAgIGdhcDogOHB4OyBmbGV4LXdyYXA6IHdyYXA7CiAgICAgICAgfQogICAg
ICAgIC5mZC1idG4gewogICAgICAgICAgICBib3JkZXI6IG5vbmU7IGJhY2tncm91bmQ6IG5vbmU7IGN1
cnNvcjogcG9pbnRlcjsKICAgICAgICAgICAgY29sb3I6IHZhcigtLXR4dDMpOyBmb250LXNpemU6IDEw
cHg7IGZvbnQtd2VpZ2h0OiA2MDA7CiAgICAgICAgICAgIHBhZGRpbmc6IDFweCAycHg7IGRpc3BsYXk6
IGlubGluZS1mbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDJweDsKICAgICAgICAgICAgd2hp
dGUtc3BhY2U6IG5vd3JhcDsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBh
cHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgICAgICB0cmFuc2l0aW9uOiBjb2xvciB2YXIoLS10cik7
CiAgICAgICAgfQogICAgICAgIC5mZC1idG46aG92ZXIgeyBjb2xvcjogdmFyKC0tYWNjKTsgfQogICAg
ICAgIC5mZC1idG4ub2sgeyBjb2xvcjogIzFmN2E1NTsgfQoKICAgICAgICAvKiDilIDilIAgQ29udGV4
dCBtZW51IOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgCAqLwogICAgICAgICNjdHgg
ewogICAgICAgICAgICBwb3NpdGlvbjogZml4ZWQ7IHotaW5kZXg6IDk5OTk7IG1pbi13aWR0aDogMTMy
cHg7IGRpc3BsYXk6IG5vbmU7IHBhZGRpbmc6IDRweDsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2Zm
ZjsgYm9yZGVyLXJhZGl1czogdmFyKC0tcik7IGJveC1zaGFkb3c6IDAgNnB4IDE2cHggcmdiYSgwLDAs
MCwuMTQpOwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246
IG5vLWRyYWc7CiAgICAgICAgfQogICAgICAgICNjdHgub24geyBkaXNwbGF5OiBibG9jazsgfQogICAg
ICAgIC5jLWl0ZW0gewogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVy
OyBnYXA6IDdweDsgcGFkZGluZzogNnB4IDlweDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogdmFy
KC0tcik7IGN1cnNvcjogcG9pbnRlcjsgZm9udC1zaXplOiAxMXB4OyBjb2xvcjogdmFyKC0tdHh0KTsK
ICAgICAgICB9CiAgICAgICAgLmMtaXRlbTpob3ZlciB7IGJhY2tncm91bmQ6ICNmMmY0Zjk7IH0KICAg
ICAgICAuYy1pdGVtLmRhbmdlciB7IGNvbG9yOiAjZmY3YjljOyB9CiAgICAgICAgLmMtc2VwIHsgaGVp
Z2h0OiAxcHg7IGJhY2tncm91bmQ6ICNlY2VmZjU7IG1hcmdpbjogM3B4IDA7IH0KICAgICAgICAuYy1p
Y28geyB3aWR0aDogMTRweDsgdGV4dC1hbGlnbjogY2VudGVyOyB9CgogICAgICAgIC8qIOKUgOKUgCBD
bGVhciBjb25maXJtIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgCAqLwogICAgICAgICNj
bHItZGxnIHsKICAgICAgICAgICAgZGlzcGxheTogbm9uZTsgcG9zaXRpb246IGZpeGVkOyBpbnNldDog
MDsgei1pbmRleDogMTAwMDA7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoMjAsIDIyLCAzNSwg
LjQyKTsKICAgICAgICAgICAgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50
ZXI7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjogbm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8t
ZHJhZzsKICAgICAgICB9CiAgICAgICAgI2Nsci1kbGcub24geyBkaXNwbGF5OiBmbGV4OyB9CiAgICAg
ICAgLmNsci1ib3ggewogICAgICAgICAgICB3aWR0aDogbWluKDI4MHB4LCBjYWxjKDEwMCUgLSAzMnB4
KSk7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNmZmY7IGJvcmRlci1yYWRpdXM6IDEycHg7CiAgICAg
ICAgICAgIGJveC1zaGFkb3c6IDAgMTJweCAzMnB4IHJnYmEoMCwwLDAsLjE4KTsKICAgICAgICAgICAg
cGFkZGluZzogMTZweCAxNnB4IDE0cHg7IGNvbG9yOiB2YXIoLS10eHQpOwogICAgICAgIH0KICAgICAg
ICAuY2xyLXRpdGxlIHsgZm9udC1zaXplOiAxNHB4OyBmb250LXdlaWdodDogNzAwOyBtYXJnaW4tYm90
dG9tOiA2cHg7IH0KICAgICAgICAuY2xyLWRlc2MgeyBmb250LXNpemU6IDExcHg7IGNvbG9yOiB2YXIo
LS10eHQzKTsgbGluZS1oZWlnaHQ6IDEuNTsgbWFyZ2luLWJvdHRvbTogMTJweDsgfQogICAgICAgIC5j
bHItY2hlY2sgewogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBn
YXA6IDdweDsKICAgICAgICAgICAgZm9udC1zaXplOiAxMnB4OyBjb2xvcjogdmFyKC0tdHh0KTsgY3Vy
c29yOiBwb2ludGVyOwogICAgICAgICAgICB1c2VyLXNlbGVjdDogbm9uZTsgbWFyZ2luLWJvdHRvbTog
MTRweDsKICAgICAgICB9CiAgICAgICAgLmNsci1jaGVjayBpbnB1dCB7CiAgICAgICAgICAgIHdpZHRo
OiAxNHB4OyBoZWlnaHQ6IDE0cHg7IGFjY2VudC1jb2xvcjogdmFyKC0tYWNjKTsgY3Vyc29yOiBwb2lu
dGVyOwogICAgICAgIH0KICAgICAgICAuY2xyLWJ0bnMgeyBkaXNwbGF5OiBmbGV4OyBnYXA6IDhweDsg
anVzdGlmeS1jb250ZW50OiBmbGV4LWVuZDsgfQogICAgICAgIC5jbHItYnRucyBidXR0b24gewogICAg
ICAgICAgICBib3JkZXI6IG5vbmU7IGJvcmRlci1yYWRpdXM6IDhweDsgcGFkZGluZzogN3B4IDE0cHg7
CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTJweDsgY3Vyc29yOiBwb2ludGVyOyBmb250LXdlaWdodDog
NjAwOwogICAgICAgICAgICB0cmFuc2l0aW9uOiBiYWNrZ3JvdW5kIHZhcigtLXRyKSwgY29sb3IgdmFy
KC0tdHIpOwogICAgICAgIH0KICAgICAgICAjY2xyLWNhbmNlbCB7IGJhY2tncm91bmQ6ICNmMWYzZjg7
IGNvbG9yOiB2YXIoLS10eHQyKTsgfQogICAgICAgICNjbHItY2FuY2VsOmhvdmVyIHsgYmFja2dyb3Vu
ZDogI2U2ZTlmMjsgfQogICAgICAgICNjbHItb2sgeyBiYWNrZ3JvdW5kOiByZ2JhKDI1NSwxMjMsMTU2
LC4xNCk7IGNvbG9yOiAjZTg1YTdhOyB9CiAgICAgICAgI2Nsci1vazpob3ZlciB7IGJhY2tncm91bmQ6
IHJnYmEoMjU1LDEyMywxNTYsLjI0KTsgfQoKICAgICAgICAvKiDilIDilIAgRmlsZSBwYXRoIHRpcCDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAgKi8KICAgICAgICAjcGF0aC10aXAgewogICAg
ICAgICAgICBkaXNwbGF5OiBub25lOyBwb3NpdGlvbjogZml4ZWQ7IHotaW5kZXg6IDEwMDAxOwogICAg
ICAgICAgICB3aWR0aDogbWluKDMyMHB4LCBjYWxjKDEwMHZ3IC0gMTZweCkpOwogICAgICAgICAgICBt
YXgtaGVpZ2h0OiBtaW4oMjgwcHgsIGNhbGMoMTAwdmggLSAyNHB4KSk7CiAgICAgICAgICAgIG92ZXJm
bG93OiBhdXRvOwogICAgICAgICAgICBwYWRkaW5nOiAwOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiBs
aW5lYXItZ3JhZGllbnQoMTY1ZGVnLCAjZmZmZmZmIDAlLCAjZjZmOGZjIDEwMCUpOwogICAgICAgICAg
ICBib3JkZXI6IDFweCBzb2xpZCByZ2JhKDcwLCA4NCwgMTIwLCAuMSk7CiAgICAgICAgICAgIGJvcmRl
ci1yYWRpdXM6IDEycHg7CiAgICAgICAgICAgIGJveC1zaGFkb3c6CiAgICAgICAgICAgICAgICAwIDRw
eCA2cHggcmdiYSgzMCwgNDAsIDcwLCAuMDQpLAogICAgICAgICAgICAgICAgMCAxNHB4IDM2cHggcmdi
YSgzMCwgNDAsIDcwLCAuMTYpOwogICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0KTsKICAgICAgICAg
ICAgcG9pbnRlci1ldmVudHM6IGF1dG87CiAgICAgICAgICAgIG9wYWNpdHk6IDA7CiAgICAgICAgICAg
IHRyYW5zZm9ybTogdHJhbnNsYXRlWSg0cHgpIHNjYWxlKC45OCk7CiAgICAgICAgICAgIHRyYW5zaXRp
b246IG9wYWNpdHkgLjE0cyBlYXNlLCB0cmFuc2Zvcm0gLjE0cyBlYXNlOwogICAgICAgICAgICAtd2Vi
a2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgfQogICAg
ICAgICNwYXRoLXRpcC5vbiB7CiAgICAgICAgICAgIGRpc3BsYXk6IGJsb2NrOwogICAgICAgICAgICBv
cGFjaXR5OiAxOwogICAgICAgICAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoMCkgc2NhbGUoMSk7CiAg
ICAgICAgfQogICAgICAgIC5wdC1oZWFkIHsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgYWxpZ24t
aXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBzcGFjZS1iZXR3ZWVuOwogICAgICAgICAgICBn
YXA6IDEwcHg7IHBhZGRpbmc6IDEwcHggMTJweCA4cHg7CiAgICAgICAgICAgIGJvcmRlci1ib3R0b206
IDFweCBzb2xpZCByZ2JhKDcwLCA4NCwgMTIwLCAuMDcpOwogICAgICAgIH0KICAgICAgICAucHQtdGl0
bGUgewogICAgICAgICAgICBmb250LXNpemU6IDExcHg7IGZvbnQtd2VpZ2h0OiA3MDA7IGxldHRlci1z
cGFjaW5nOiAuMDRlbTsKICAgICAgICAgICAgY29sb3I6IHZhcigtLXR4dDIpOyB0ZXh0LXRyYW5zZm9y
bTogdXBwZXJjYXNlOwogICAgICAgICAgICBmbGV4LXNocmluazogMDsKICAgICAgICB9CiAgICAgICAg
LnB0LWhlYWQtYnRuIHsKICAgICAgICAgICAgZmxleC1zaHJpbms6IDA7IG1hcmdpbi1sZWZ0OiBhdXRv
OwogICAgICAgICAgICBoZWlnaHQ6IDIycHg7IHBhZGRpbmc6IDAgOHB4OyBkaXNwbGF5OiBpbmxpbmUt
ZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA0cHg7CiAgICAgICAgICAgIGJvcmRlcjogMXB4
IHNvbGlkIHJnYmEoMTA3LDExMiwxMjgsLjIyKTsgYm9yZGVyLXJhZGl1czogNnB4OyBjdXJzb3I6IHBv
aW50ZXI7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoMTA3LDExMiwxMjgsLjA2KTsgY29sb3I6
ICM4YTkwYTA7IGZvbnQtc2l6ZTogMTFweDsgZm9udC13ZWlnaHQ6IDYwMDsKICAgICAgICAgICAgd2hp
dGUtc3BhY2U6IG5vd3JhcDsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBh
cHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgICAgICB0cmFuc2l0aW9uOiBiYWNrZ3JvdW5kIHZhcigt
LXRyKSwgY29sb3IgdmFyKC0tdHIpLCBib3JkZXItY29sb3IgdmFyKC0tdHIpOwogICAgICAgIH0KICAg
ICAgICAucHQtaGVhZC1idG46aG92ZXIgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDEwNywx
MTIsMTI4LC4xMik7IGNvbG9yOiB2YXIoLS10eHQyKTsKICAgICAgICAgICAgYm9yZGVyLWNvbG9yOiBy
Z2JhKDEwNywxMTIsMTI4LC40KTsKICAgICAgICB9CiAgICAgICAgLnB0LWxpc3QgeyBwYWRkaW5nOiA2
cHggOHB4IDhweDsgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgZ2FwOiA0cHg7
IH0KICAgICAgICAucHQtcm93IHsKICAgICAgICAgICAgZGlzcGxheTogZ3JpZDsgZ3JpZC10ZW1wbGF0
ZS1jb2x1bW5zOiA4cHggMWZyOyBnYXA6IDhweDsKICAgICAgICAgICAgcGFkZGluZzogOHB4IDhweDsg
Ym9yZGVyLXJhZGl1czogOHB4OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDI1NSwyNTUsMjU1
LC43KTsKICAgICAgICB9CiAgICAgICAgLnB0LXJvdy5kZWFkIHsgYmFja2dyb3VuZDogcmdiYSgyNTUs
IDEyMywgMTU2LCAuMDYpOyB9CiAgICAgICAgLnB0LWRvdCB7CiAgICAgICAgICAgIHdpZHRoOiA4cHg7
IGhlaWdodDogOHB4OyBib3JkZXItcmFkaXVzOiA1MCU7IG1hcmdpbi10b3A6IDVweDsKICAgICAgICAg
ICAgYmFja2dyb3VuZDogIzJlYjQ3ODsgYm94LXNoYWRvdzogMCAwIDAgM3B4IHJnYmEoNDYsIDE4MCwg
MTIwLCAuMTgpOwogICAgICAgIH0KICAgICAgICAucHQtcm93LmRlYWQgLnB0LWRvdCB7CiAgICAgICAg
ICAgIGJhY2tncm91bmQ6ICNlODVhN2E7IGJveC1zaGFkb3c6IDAgMCAwIDNweCByZ2JhKDIzMiwgOTAs
IDEyMiwgLjE2KTsKICAgICAgICB9CiAgICAgICAgLnB0LW5hbWUgewogICAgICAgICAgICBmb250LXNp
emU6IDEycHg7IGZvbnQtd2VpZ2h0OiA2NTA7IGNvbG9yOiB2YXIoLS10eHQpOwogICAgICAgICAgICBs
aW5lLWhlaWdodDogMS4zOyB3b3JkLWJyZWFrOiBicmVhay1hbGw7CiAgICAgICAgfQogICAgICAgIC5w
dC1wYXRoIHsKICAgICAgICAgICAgbWFyZ2luLXRvcDogM3B4OwogICAgICAgICAgICBmb250OiAxMC41
cHgvMS40NSAnQ2FzY2FkaWEgTW9ubycsJ0NvbnNvbGFzJywnTWljcm9zb2Z0IFlhSGVpIFVJJyxtb25v
c3BhY2U7CiAgICAgICAgICAgIGNvbG9yOiB2YXIoLS10eHQyKTsgd29yZC1icmVhazogYnJlYWstYWxs
OwogICAgICAgICAgICB1c2VyLXNlbGVjdDogdGV4dDsKICAgICAgICB9CiAgICAgICAgLnB0LXBhdGgu
bGl2ZSB7CiAgICAgICAgICAgIGNvbG9yOiB2YXIoLS1hY2MpOyBjdXJzb3I6IHBvaW50ZXI7CiAgICAg
ICAgfQogICAgICAgIC5wdC1wYXRoLmxpdmU6aG92ZXIgeyB0ZXh0LWRlY29yYXRpb246IHVuZGVybGlu
ZTsgfQogICAgICAgIC5wdC1wYXRoLmRlYWQgewogICAgICAgICAgICBjb2xvcjogI2M0M2Q1YzsKICAg
ICAgICAgICAgdGV4dC1kZWNvcmF0aW9uOiBsaW5lLXRocm91Z2g7CiAgICAgICAgICAgIHRleHQtZGVj
b3JhdGlvbi10aGlja25lc3M6IDJweDsKICAgICAgICAgICAgdGV4dC1kZWNvcmF0aW9uLWNvbG9yOiAj
ZTExZDQ4OwogICAgICAgICAgICBjdXJzb3I6IGRlZmF1bHQ7CiAgICAgICAgfQogICAgICAgIC5wdC1h
Y3Rpb25zIHsKICAgICAgICAgICAgbWFyZ2luLXRvcDogNnB4OwogICAgICAgICAgICBkaXNwbGF5OiBm
bGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDZweDsgZmxleC13cmFwOiB3cmFwOwogICAgICAg
IH0KICAgICAgICAucHQtY29weS1idG4gewogICAgICAgICAgICBoZWlnaHQ6IDIycHg7IHBhZGRpbmc6
IDAgOHB4OyBkaXNwbGF5OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsKICAgICAgICAg
ICAgYm9yZGVyOiAxcHggc29saWQgcmdiYSgxMDcsMTEyLDEyOCwuMjIpOyBib3JkZXItcmFkaXVzOiA2
cHg7IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICAgICAgYmFja2dyb3VuZDogcmdiYSgxMDcsMTEyLDEy
OCwuMDYpOyBjb2xvcjogIzhhOTBhMDsgZm9udC1zaXplOiAxMXB4OyBmb250LXdlaWdodDogNjAwOwog
ICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRyYWc7IGFwcC1yZWdpb246IG5vLWRyYWc7
CiAgICAgICAgICAgIHRyYW5zaXRpb246IGJhY2tncm91bmQgdmFyKC0tdHIpLCBjb2xvciB2YXIoLS10
ciksIGJvcmRlci1jb2xvciB2YXIoLS10cik7CiAgICAgICAgfQogICAgICAgIC5wdC1jb3B5LWJ0bjpo
b3ZlciB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6IHJnYmEoMTA3LDExMiwxMjgsLjEyKTsgY29sb3I6
IHZhcigtLXR4dDIpOwogICAgICAgICAgICBib3JkZXItY29sb3I6IHJnYmEoMTA3LDExMiwxMjgsLjQp
OwogICAgICAgIH0KICAgICAgICAucHQtY29weS1idG4ub2sgewogICAgICAgICAgICBjb2xvcjogIzFm
N2E1NTsgYm9yZGVyLWNvbG9yOiByZ2JhKDQ2LCAxODAsIDEyMCwgLjM1KTsKICAgICAgICAgICAgYmFj
a2dyb3VuZDogcmdiYSg0NiwgMTgwLCAxMjAsIC4xKTsKICAgICAgICB9CiAgICAgICAgLml0bS5pdC1n
cm91cCB7CiAgICAgICAgICAgIGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47CiAgICAgICAgICAgIGFsaWdu
LWl0ZW1zOiBzdHJldGNoOwogICAgICAgICAgICBnYXA6IDA7CiAgICAgICAgICAgIHBhZGRpbmc6IDZw
eCA4cHggNHB4OwogICAgICAgICAgICBjdXJzb3I6IGRlZmF1bHQ7CiAgICAgICAgfQogICAgICAgIC5p
dG0uaXQtZ3JvdXA6aG92ZXIgeyBiYWNrZ3JvdW5kOiB2YXIoLS1jYXJkKTsgfQogICAgICAgIC5tZy1o
ZWFkIHsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA2
cHg7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTFweDsgY29sb3I6IHZhcigtLXR4dDMpOyBmb250LXdl
aWdodDogNjAwOwogICAgICAgICAgICBwYWRkaW5nOiAycHggMnB4IDZweDsgdXNlci1zZWxlY3Q6IG5v
bmU7CiAgICAgICAgfQogICAgICAgIC5tZy1oZWFkIC5tZy10YWcgewogICAgICAgICAgICBkaXNwbGF5
OiBpbmxpbmUtZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsKICAgICAgICAgICAgaGVpZ2h0OiAxNnB4
OyBwYWRkaW5nOiAwIDZweDsgYm9yZGVyLXJhZGl1czogOHB4OwogICAgICAgICAgICBiYWNrZ3JvdW5k
OiByZ2JhKDkxLDExNSwyMzIsLjEyKTsgY29sb3I6IHZhcigtLWFjYyk7IGZvbnQtc2l6ZTogMTBweDsK
ICAgICAgICB9CiAgICAgICAgLm1nLXJvdyB7CiAgICAgICAgICAgIHBhZGRpbmc6IDdweCA2cHg7IG1h
cmdpbi1ib3R0b206IDNweDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogNXB4OyBjdXJzb3I6IHBv
aW50ZXI7CiAgICAgICAgICAgIGJvcmRlcjogMXB4IHNvbGlkIHRyYW5zcGFyZW50OwogICAgICAgICAg
ICB0cmFuc2l0aW9uOiBiYWNrZ3JvdW5kIC4xMnMgZWFzZSwgYm9yZGVyLWNvbG9yIC4xMnMgZWFzZTsK
ICAgICAgICB9CiAgICAgICAgLm1nLXJvdzpob3ZlciB7IGJhY2tncm91bmQ6IHZhcigtLWNhcmQtaCk7
IH0KICAgICAgICAubWctcm93LnNlbCB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNlZGYxZmY7CiAg
ICAgICAgICAgIGJvcmRlci1jb2xvcjogcmdiYSg5MSwxMTUsMjMyLC4zNSk7CiAgICAgICAgICAgIGJv
eC1zaGFkb3c6IDAgMCAwIDFweCByZ2JhKDkxLDExNSwyMzIsLjI1KTsKICAgICAgICB9CiAgICAgICAg
Lm1nLXJvdy5tdWx0aSB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNlZWYyZmY7CiAgICAgICAgICAg
IGJvcmRlci1jb2xvcjogcmdiYSg5MSwxMTUsMjMyLC40NSk7CiAgICAgICAgfQogICAgICAgIC5tZy10
aXRsZSB7CiAgICAgICAgICAgIGZvbnQtc2l6ZTogMTNweDsgZm9udC13ZWlnaHQ6IDYwMDsgY29sb3I6
IHZhcigtLWFjYyk7CiAgICAgICAgICAgIG1hcmdpbi1ib3R0b206IDJweDsgbGluZS1oZWlnaHQ6IDEu
MzU7CiAgICAgICAgICAgIGRpc3BsYXk6IC13ZWJraXQtYm94OyAtd2Via2l0LWJveC1vcmllbnQ6IHZl
cnRpY2FsOyAtd2Via2l0LWxpbmUtY2xhbXA6IDI7CiAgICAgICAgICAgIG92ZXJmbG93OiBoaWRkZW47
IHdvcmQtYnJlYWs6IGJyZWFrLXdvcmQ7CiAgICAgICAgfQogICAgICAgIC5tZy1ib2R5IHsKICAgICAg
ICAgICAgZm9udC1zaXplOiAxMi41cHg7IGZvbnQtd2VpZ2h0OiA1MDA7IGNvbG9yOiB2YXIoLS10eHQp
OwogICAgICAgICAgICB3aGl0ZS1zcGFjZTogcHJlLXdyYXA7IHdvcmQtYnJlYWs6IGJyZWFrLWFsbDsK
ICAgICAgICAgICAgZGlzcGxheTogLXdlYmtpdC1ib3g7IC13ZWJraXQtYm94LW9yaWVudDogdmVydGlj
YWw7IC13ZWJraXQtbGluZS1jbGFtcDogNDsKICAgICAgICAgICAgb3ZlcmZsb3c6IGhpZGRlbjsgbGlu
ZS1oZWlnaHQ6IDEuNDsKICAgICAgICB9CiAgICAgICAgLm1nLWJvZHkuaW1nIHsgY29sb3I6IHZhcigt
LXR4dDIpOyB9CiAgICAgICAgLm1nLXJvdy10b3AgewogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBh
bGlnbi1pdGVtczogZmxleC1zdGFydDsgZ2FwOiA4cHg7CiAgICAgICAgfQogICAgICAgIC5tZy1yb3ct
bWFpbiB7IGZsZXg6IDE7IG1pbi13aWR0aDogMDsgfQogICAgICAgIC5tZy1zcmMgewogICAgICAgICAg
ICB3aWR0aDogMThweDsgaGVpZ2h0OiAxOHB4OyBmbGV4LXNocmluazogMDsgbWFyZ2luLXRvcDogMnB4
OwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiAzcHg7IG9iamVjdC1maXQ6IGNvbnRhaW47CiAgICAg
ICAgICAgIGJhY2tncm91bmQ6IHJnYmEoMCwwLDAsLjA0KTsKICAgICAgICB9CiAgICAgICAgLmktZmF2
LXRpdGxlIHsKICAgICAgICAgICAgZm9udC1zaXplOiAxM3B4OyBmb250LXdlaWdodDogNjAwOyBjb2xv
cjogdmFyKC0tYWNjKTsKICAgICAgICAgICAgbWFyZ2luOiAwIDAgM3B4OyBsaW5lLWhlaWdodDogMS4z
NTsKICAgICAgICAgICAgZGlzcGxheTogLXdlYmtpdC1ib3g7IC13ZWJraXQtYm94LW9yaWVudDogdmVy
dGljYWw7IC13ZWJraXQtbGluZS1jbGFtcDogMjsKICAgICAgICAgICAgb3ZlcmZsb3c6IGhpZGRlbjsg
d29yZC1icmVhazogYnJlYWstd29yZDsKICAgICAgICB9CiAgICAgICAgI3RpdGxlLWRsZyB7CiAgICAg
ICAgICAgIGRpc3BsYXk6IG5vbmU7IHBvc2l0aW9uOiBmaXhlZDsgaW5zZXQ6IDA7IHotaW5kZXg6IDEw
MDsKICAgICAgICAgICAgYmFja2dyb3VuZDogcmdiYSgxNSwxOCwyOCwuMzUpOwogICAgICAgICAgICBh
bGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAgICAgICB9CiAgICAg
ICAgI3RpdGxlLWRsZy5vbiB7IGRpc3BsYXk6IGZsZXg7IH0KICAgICAgICAjdGl0bGUtZGxnIC50aXRs
ZS1ib3ggewogICAgICAgICAgICB3aWR0aDogMjYwcHg7IHBhZGRpbmc6IDE2cHggMTZweCAxMnB4Owog
ICAgICAgICAgICBiYWNrZ3JvdW5kOiB2YXIoLS1jYXJkKTsgYm9yZGVyLXJhZGl1czogMTBweDsKICAg
ICAgICAgICAgYm94LXNoYWRvdzogMCA4cHggMjhweCByZ2JhKDAsMCwwLC4xOCk7CiAgICAgICAgfQog
ICAgICAgICN0aXRsZS1pbnB1dCB7CiAgICAgICAgICAgIHdpZHRoOiAxMDAlOyBib3gtc2l6aW5nOiBi
b3JkZXItYm94OyBtYXJnaW46IDhweCAwIDEycHg7CiAgICAgICAgICAgIGhlaWdodDogMzJweDsgcGFk
ZGluZzogMCAxMHB4OyBib3JkZXItcmFkaXVzOiA2cHg7CiAgICAgICAgICAgIGJvcmRlcjogMXB4IHNv
bGlkICNkNWRhZTY7IGJhY2tncm91bmQ6ICNmZmY7IGNvbG9yOiB2YXIoLS10eHQpOwogICAgICAgICAg
ICBmb250LXNpemU6IDEzcHg7IG91dGxpbmU6IG5vbmU7CiAgICAgICAgfQogICAgICAgICN0aXRsZS1p
bnB1dDpmb2N1cyB7IGJvcmRlci1jb2xvcjogdmFyKC0tYWNjKTsgfQoKICAgIAogICAgICAgIC8qIHVp
LWdyYXktYmctdjEgKi8KICAgICAgICA6cm9vdCB7CiAgICAgICAgICAgIC0tYmc6ICNlNGU3ZWUgIWlt
cG9ydGFudDsKICAgICAgICB9CiAgICAgICAgaHRtbCwgYm9keSB7CiAgICAgICAgICAgIGJhY2tncm91
bmQ6ICNlNGU3ZWUgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgI2FwcCB7CiAgICAgICAgICAg
IGJhY2tncm91bmQ6IGxpbmVhci1ncmFkaWVudCgxODBkZWcsICNlOWVjZjMgMCUsICNlMGU0ZWMgMTAw
JSkgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgI2hkciB7CiAgICAgICAgICAgIGJhY2tncm91
bmQ6ICNlMmU2ZWUgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAgICAgI3RhYnMgewogICAgICAgICAg
ICBiYWNrZ3JvdW5kOiAjZTJlNmVlICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgICNsaXN0LCAj
ZW1wdHksICNza2VsLCAjaGRyLWdyb3csICNzZWFyY2gtd3JhcCB7CiAgICAgICAgICAgIGJhY2tncm91
bmQ6IHRyYW5zcGFyZW50ICFpbXBvcnRhbnQ7CiAgICAgICAgfQogICAgICAgICNzZWFyY2gtYm94IHsK
ICAgICAgICAgICAgdHJhbnNmb3JtLW9yaWdpbjogcmlnaHQgY2VudGVyOwogICAgICAgICAgICBiYWNr
Z3JvdW5kOiB0cmFuc3BhcmVudCAhaW1wb3J0YW50OwogICAgICAgIH0KICAgICAgICAuaXRtLCAubWcs
IC5tZy1yb3csIC5tZXJnZS1ncm91cCB7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNmZmZmZmYgIWlt
cG9ydGFudDsKICAgICAgICB9CiAgICAgICAgLml0bTpob3ZlciB7CiAgICAgICAgICAgIGJhY2tncm91
bmQ6ICNmOGY5ZmMgIWltcG9ydGFudDsKICAgICAgICB9CiAgICAKICAgICAgICAvKiBzZWwtdGludC1i
bHVlLXYxICovCiAgICAgICAgLml0bS5zZWwsCiAgICAgICAgLm1nLXJvdy5zZWwsCiAgICAgICAgLml0
bS5tdWx0aSwKICAgICAgICAubWctcm93Lm11bHRpLAogICAgICAgIC5pdG0ubXVsdGkuc2VsLAogICAg
ICAgIC5pdC1ncm91cC5zZWwsCiAgICAgICAgLml0LWdyb3VwLm11bHRpIHsKICAgICAgICAgICAgYmFj
a2dyb3VuZDogI2U4ZWZmZiAhaW1wb3J0YW50OwogICAgICAgIH0KICAgICAgICAuaXRtLnNlbDpob3Zl
ciwKICAgICAgICAuaXRtLm11bHRpOmhvdmVyLAogICAgICAgIC5tZy1yb3cuc2VsOmhvdmVyLAogICAg
ICAgIC5tZy1yb3cubXVsdGk6aG92ZXIgewogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZGRlNmZmICFp
bXBvcnRhbnQ7CiAgICAgICAgfQogICAgCiAgICAgICAgLyogaG92ZXItZ3JlZW4tcmlzZS12MiAqLwog
ICAgICAgIC8qIGhvdmVyLWFjY2VudC1yaXNlLXYzICovCiAgICAgICAgLml0bSB7IHBvc2l0aW9uOiBy
ZWxhdGl2ZSAhaW1wb3J0YW50OyBvdmVyZmxvdzogaGlkZGVuICFpbXBvcnRhbnQ7IH0KICAgICAgICAu
aXRtOjpiZWZvcmUgewogICAgICAgICAgICBjb250ZW50OiAiIiAhaW1wb3J0YW50OwogICAgICAgICAg
ICBwb3NpdGlvbjogYWJzb2x1dGUgIWltcG9ydGFudDsKICAgICAgICAgICAgbGVmdDogMCAhaW1wb3J0
YW50OyByaWdodDogMCAhaW1wb3J0YW50OyBib3R0b206IDAgIWltcG9ydGFudDsKICAgICAgICAgICAg
aGVpZ2h0OiAwICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIHBvaW50ZXItZXZlbnRzOiBub25lICFpbXBv
cnRhbnQ7CiAgICAgICAgICAgIHotaW5kZXg6IDAgIWltcG9ydGFudDsKICAgICAgICAgICAgYm9yZGVy
LXJhZGl1czogMCAwIHZhcigtLXIsIDRweCkgdmFyKC0tciwgNHB4KSAhaW1wb3J0YW50OwogICAgICAg
ICAgICBiYWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGllbnQodG8gdG9wLAogICAgICAgICAgICAgICAgcmdi
YSg5MSwgMTE1LCAyMzIsIC4zMikgMCUsCiAgICAgICAgICAgICAgICByZ2JhKDkxLCAxMTUsIDIzMiwg
LjEyKSA1NSUsCiAgICAgICAgICAgICAgICByZ2JhKDkxLCAxMTUsIDIzMiwgMCkgMTAwJSkgIWltcG9y
dGFudDsKICAgICAgICAgICAgdHJhbnNpdGlvbjogaGVpZ2h0IC4zNHMgY3ViaWMtYmV6aWVyKC4yMiwg
MSwgLjM2LCAxKSAhaW1wb3J0YW50OwogICAgICAgIH0KICAgICAgICAuaXRtOmhvdmVyOjpiZWZvcmUg
eyBoZWlnaHQ6IDMzLjMzMyUgIWltcG9ydGFudDsgfQogICAgICAgIC5pdG06OmFmdGVyIHsKICAgICAg
ICAgICAgY29udGVudDogIiIgIWltcG9ydGFudDsKICAgICAgICAgICAgcG9zaXRpb246IGFic29sdXRl
ICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIGxlZnQ6IDAgIWltcG9ydGFudDsgcmlnaHQ6IDAgIWltcG9y
dGFudDsgYm90dG9tOiAwICFpbXBvcnRhbnQ7CiAgICAgICAgICAgIGhlaWdodDogMnB4ICFpbXBvcnRh
bnQ7CiAgICAgICAgICAgIHBvaW50ZXItZXZlbnRzOiBub25lICFpbXBvcnRhbnQ7CiAgICAgICAgICAg
IHotaW5kZXg6IDEgIWltcG9ydGFudDsKICAgICAgICAgICAgYmFja2dyb3VuZDogcmdiYSg5MSwgMTE1
LCAyMzIsIC45MikgIWltcG9ydGFudDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogMXB4ICFpbXBv
cnRhbnQ7CiAgICAgICAgICAgIHRyYW5zZm9ybTogc2NhbGVYKDApICFpbXBvcnRhbnQ7CiAgICAgICAg
ICAgIHRyYW5zZm9ybS1vcmlnaW46IGNlbnRlciAhaW1wb3J0YW50OwogICAgICAgICAgICB0cmFuc2l0
aW9uOiB0cmFuc2Zvcm0gLjNzIGN1YmljLWJlemllciguMjIsIDEsIC4zNiwgMSkgIWltcG9ydGFudDsK
ICAgICAgICB9CiAgICAgICAgLml0bTpob3Zlcjo6YWZ0ZXIgewogICAgICAgICAgICB0cmFuc2Zvcm06
IHNjYWxlWCgxKSAhaW1wb3J0YW50OwogICAgICAgICAgICBiYWNrZ3JvdW5kOiByZ2JhKDkxLCAxMTUs
IDIzMiwgLjk1KSAhaW1wb3J0YW50OwogICAgICAgIH0KICAgICAgICAuaXRtID4gKiB7IHBvc2l0aW9u
OiByZWxhdGl2ZTsgei1pbmRleDogMjsgfQogICAgICAgICAgICAvKiB3aGl0ZS1wYW5lbC1ib3JkZXI6
IG91dGVyIGVkZ2UgbGluZSByZW1vdmVkICovCiAgICAgICAgI2FwcCB7CiAgICAgICAgICAgIGJvcmRl
cjogbm9uZSAhaW1wb3J0YW50OwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiAwICFpbXBvcnRhbnQ7
CiAgICAgICAgICAgIGJveC1zaXppbmc6IGJvcmRlci1ib3ggIWltcG9ydGFudDsKICAgICAgICAgICAg
b3ZlcmZsb3c6IGhpZGRlbiAhaW1wb3J0YW50OwogICAgICAgIH0KICAgICAgICAuaXRtLCAubWcsIC5t
Zy1yb3csIC5tZXJnZS1ncm91cCB7CiAgICAgICAgICAgIGJvcmRlcjogMXB4IHNvbGlkICNmZmZmZmYg
IWltcG9ydGFudDsKICAgICAgICB9CiAgICA8L3N0eWxlPgo8L2hlYWQ+Cjxib2R5Pgo8ZGl2IGlkPSJh
cHAiIGNsYXNzPSJib290LWxvYWRpbmciPgogICAgPGRpdiBpZD0iaGRyIj4KICAgICAgICA8ZGl2IGlk
PSJoZWFydCI+CiAgICAgICAgICAgIDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBz
dHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiCiAgICAgICAgICAgICAgICAgc3Ry
b2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIj4KICAgICAgICAgICAgICAg
IDxyZWN0IHg9IjkiIHk9IjIiIHdpZHRoPSI2IiBoZWlnaHQ9IjQiIHJ4PSIxIi8+CiAgICAgICAgICAg
ICAgICA8cGF0aCBkPSJNMTYgNGgyYTIgMiAwIDAgMSAyIDJ2MTRhMiAyIDAgMCAxLTIgMkg2YTIgMiAw
IDAgMS0yLTJWNmEyIDIgMCAwIDEgMi0yaDIiLz4KICAgICAgICAgICAgICAgIDxwYXRoIGQ9Ik05IDEy
aDZNOSAxNmg0Ii8+CiAgICAgICAgICAgIDwvc3ZnPgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYg
aWQ9Imhkci1ncm93Ij48L2Rpdj4KICAgICAgICA8YnV0dG9uIGlkPSJidG4tbG9jYXRlIiB0eXBlPSJi
dXR0b24iIHRpdGxlPSLlrprkvY3liLDkuIrmrKHkvb/nlKjnmoTmnaHnm64iIGRpc2FibGVkPgogICAg
ICAgICAgICA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50
Q29sb3IiIHN0cm9rZS13aWR0aD0iMiIKICAgICAgICAgICAgICAgICBzdHJva2UtbGluZWNhcD0icm91
bmQiIHN0cm9rZS1saW5lam9pbj0icm91bmQiPgogICAgICAgICAgICAgICAgPGNpcmNsZSBjeD0iMTIi
IGN5PSIxMiIgcj0iOCIvPgogICAgICAgICAgICAgICAgPGNpcmNsZSBjeD0iMTIiIGN5PSIxMiIgcj0i
My41Ii8+CiAgICAgICAgICAgIDwvc3ZnPgogICAgICAgIDwvYnV0dG9uPgogICAgICAgIDxkaXYgaWQ9
InNlYXJjaC13cmFwIj4KICAgICAgICAgICAgPGJ1dHRvbiBpZD0iYnRuLXNlYXJjaCIgdHlwZT0iYnV0
dG9uIiB0aXRsZT0i5pCc57SiIj4KICAgICAgICAgICAgICAgIDxzdmcgdmlld0JveD0iMCAwIDI0IDI0
IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyIgogICAgICAg
ICAgICAgICAgICAgICBzdHJva2UtbGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9pbj0icm91bmQi
PgogICAgICAgICAgICAgICAgICAgIDxjaXJjbGUgY3g9IjExIiBjeT0iMTEiIHI9IjciLz4KICAgICAg
ICAgICAgICAgICAgICA8cGF0aCBkPSJNMjAgMjBsLTMuNS0zLjUiLz4KICAgICAgICAgICAgICAgIDwv
c3ZnPgogICAgICAgICAgICA8L2J1dHRvbj4KICAgICAgICAgICAgPGRpdiBpZD0ic2VhcmNoLWJveCI+
CiAgICAgICAgICAgICAgICA8YnV0dG9uIGlkPSJidG4tdG9kYXkiIHR5cGU9ImJ1dHRvbiI+5b2T5aSp
PC9idXR0b24+CiAgICAgICAgICAgICAgICA8aW5wdXQgaWQ9InNlYXJjaCIgdHlwZT0idGV4dCIgcGxh
Y2Vob2xkZXI9IuaQnOe0ouKApiBhfGJ8YyDpobvlkIzml7bljIXlkKsiIGF1dG9jb21wbGV0ZT0ib2Zm
IiBzcGVsbGNoZWNrPSJmYWxzZSI+CiAgICAgICAgICAgICAgICA8YnV0dG9uIGlkPSJzZWFyY2gtY2xy
IiB0eXBlPSJidXR0b24iPuKclTwvYnV0dG9uPgogICAgICAgICAgICA8L2Rpdj4KICAgICAgICA8L2Rp
dj4KICAgICAgICA8YnV0dG9uIGlkPSJidG4tcGluIiB0eXBlPSJidXR0b24iIHRpdGxlPSLpkonlnKjl
sY/luZXkuIoiPgogICAgICAgICAgICA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIg
c3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMiIKICAgICAgICAgICAgICAgICBzdHJv
a2UtbGluZWpvaW49InJvdW5kIiBzdHJva2UtbGluZWNhcD0icm91bmQiPgogICAgICAgICAgICAgICAg
PGxpbmUgeDE9IjEyIiB5MT0iMTciIHgyPSIxMiIgeTI9IjIyIi8+CiAgICAgICAgICAgICAgICA8cGF0
aCBkPSJNNSAxN2gxNHYtMS43NmEyIDIgMCAwIDAtMS4xMS0xLjc5bC0xLjc4LS45QTIgMiAwIDAgMSAx
NSAxMC43NlY2aDFhMiAyIDAgMCAwIDAtNEg4YTIgMiAwIDAgMCAwIDRoMXY0Ljc2YTIgMiAwIDAgMS0x
LjExIDEuNzlsLTEuNzguOUEyIDIgMCAwIDAgNSAxNS4yNFoiLz4KICAgICAgICAgICAgPC9zdmc+CiAg
ICAgICAgPC9idXR0b24+CiAgICA8L2Rpdj4KCiAgICA8ZGl2IGlkPSJ0YWJzIj4KICAgICAgICA8ZGl2
IGlkPSJ0YWItaW5rIiBhcmlhLWhpZGRlbj0idHJ1ZSI+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0i
dGFiIG9uIiBkYXRhLXRhYj0iYWxsIj7lhajpg6g8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJ0YWIi
IGRhdGEtdGFiPSJ0ZXh0Ij7mlofmnKw8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJ0YWIiIGRhdGEt
dGFiPSJpbWFnZSI+5Zu+5YOPPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0idGFiIiBkYXRhLXRhYj0i
ZmlsZSI+5paH5Lu2PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0idGFiIiBkYXRhLXRhYj0icGlubmVk
Ij7mlLbol48gPHNwYW4gY2xhc3M9ImJhZGdlIiBpZD0icGluLWNudCIgc3R5bGU9ImRpc3BsYXk6bm9u
ZSI+MDwvc3Bhbj48L2Rpdj4KICAgICAgICA8ZGl2IGlkPSJ0YWItYWN0aW9ucyI+CiAgICAgICAgICAg
IDxidXR0b24gaWQ9Im11bHRpLWNudCIgdHlwZT0iYnV0dG9uIiB0aXRsZT0i5Y+W5raI5aSa6YCJIj7l
t7LpgIkgMDwvYnV0dG9uPgogICAgICAgICAgICA8c3BhbiBpZD0iYmFyLXR4dCI+MDwvc3Bhbj4KICAg
ICAgICAgICAgPGJ1dHRvbiBpZD0iYnRuLWNsciIgdHlwZT0iYnV0dG9uIiB0aXRsZT0i5riF56m65Y6G
5Y+yIj4KICAgICAgICAgICAgICAgIDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBz
dHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyIgogICAgICAgICAgICAgICAgICAgICBz
dHJva2UtbGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9pbj0icm91bmQiPgogICAgICAgICAgICAg
ICAgICAgIDxwb2x5bGluZSBwb2ludHM9IjMgNiA1IDYgMjEgNiIvPgogICAgICAgICAgICAgICAgICAg
IDxwYXRoIGQ9Ik0xOSA2bC0xIDE0YTIgMiAwIDAgMS0yIDJIOGEyIDIgMCAwIDEtMi0yTDUgNiIvPgog
ICAgICAgICAgICAgICAgICAgIDxwYXRoIGQ9Ik0xMCAxMXY2TTE0IDExdjZNOSA2VjRoNnYyIi8+CiAg
ICAgICAgICAgICAgICA8L3N2Zz4KICAgICAgICAgICAgPC9idXR0b24+CiAgICAgICAgPC9kaXY+CiAg
ICA8L2Rpdj4KCiAgICA8ZGl2IGlkPSJsaXN0Ij4KICAgICAgICA8ZGl2IGlkPSJza2VsIiBjbGFzcz0i
b24iIGFyaWEtaGlkZGVuPSJ0cnVlIj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0ic2stcm93Ij48ZGl2
IGNsYXNzPSJzay1pY28iPjwvZGl2PjxkaXYgY2xhc3M9InNrLWJvZHkiPjxkaXYgY2xhc3M9InNrLWxp
bmUgbWlkIj48L2Rpdj48ZGl2IGNsYXNzPSJzay1saW5lIHNob3J0Ij48L2Rpdj48L2Rpdj48L2Rpdj4K
ICAgICAgICAgICAgPGRpdiBjbGFzcz0ic2stcm93Ij48ZGl2IGNsYXNzPSJzay1pY28iPjwvZGl2Pjxk
aXYgY2xhc3M9InNrLWJvZHkiPjxkaXYgY2xhc3M9InNrLWxpbmUiPjwvZGl2PjxkaXYgY2xhc3M9InNr
LWxpbmUgbWlkIj48L2Rpdj48L2Rpdj48L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0ic2stcm93
Ij48ZGl2IGNsYXNzPSJzay1pY28iPjwvZGl2PjxkaXYgY2xhc3M9InNrLWJvZHkiPjxkaXYgY2xhc3M9
InNrLWxpbmUgbWlkIj48L2Rpdj48ZGl2IGNsYXNzPSJzay1saW5lIHNob3J0Ij48L2Rpdj48L2Rpdj48
L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0ic2stcm93Ij48ZGl2IGNsYXNzPSJzay1pY28iPjwv
ZGl2PjxkaXYgY2xhc3M9InNrLWJvZHkiPjxkaXYgY2xhc3M9InNrLWxpbmUiPjwvZGl2PjxkaXYgY2xh
c3M9InNrLWxpbmUgbWlkIj48L2Rpdj48L2Rpdj48L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0i
c2stcm93Ij48ZGl2IGNsYXNzPSJzay1pY28iPjwvZGl2PjxkaXYgY2xhc3M9InNrLWJvZHkiPjxkaXYg
Y2xhc3M9InNrLWxpbmUgbWlkIj48L2Rpdj48ZGl2IGNsYXNzPSJzay1saW5lIHNob3J0Ij48L2Rpdj48
L2Rpdj48L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0ic2stcm93Ij48ZGl2IGNsYXNzPSJzay1p
Y28iPjwvZGl2PjxkaXYgY2xhc3M9InNrLWJvZHkiPjxkaXYgY2xhc3M9InNrLWxpbmUiPjwvZGl2Pjxk
aXYgY2xhc3M9InNrLWxpbmUgc2hvcnQiPjwvZGl2PjwvZGl2PjwvZGl2PgogICAgICAgIDwvZGl2Pgog
ICAgICAgIDxkaXYgaWQ9ImVtcHR5Ij4KICAgICAgICAgICAgPGRpdiBjbGFzcz0iZS10eHQiIGlkPSJl
bXB0eS10eHQiPuaaguaXoOiusOW9le+8jOWkjeWItuWQjuiHquWKqOWHuueOsDwvZGl2PgogICAgICAg
IDwvZGl2PgogICAgPC9kaXY+CiAgICA8YnV0dG9uIGlkPSJidG4tdG9wIiB0eXBlPSJidXR0b24iIHRp
dGxlPSLlm57liLDpobbpg6giIGFyaWEtbGFiZWw9IuWbnuWIsOmhtumDqCI+CiAgICAgICAgPHN2ZyB2
aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Ut
d2lkdGg9IjIuMiIKICAgICAgICAgICAgIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVq
b2luPSJyb3VuZCI+CiAgICAgICAgICAgIDxwYXRoIGQ9Ik0xMiAxOVY1Ii8+CiAgICAgICAgICAgIDxw
YXRoIGQ9Ik01IDEybDctNyA3IDciLz4KICAgICAgICA8L3N2Zz4KICAgIDwvYnV0dG9uPgo8L2Rpdj4K
CjxkaXYgaWQ9ImN0eCI+CiAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0iIGlkPSJjLWNvcHkiPjxzcGFuIGNs
YXNzPSJjLWljbyI+4o6YPC9zcGFuPuWkjeWItjwvZGl2PgogICAgPGRpdiBjbGFzcz0iYy1pdGVtIiBp
ZD0iYy1wYXN0ZSI+PHNwYW4gY2xhc3M9ImMtaWNvIj7ij448L3NwYW4+57KY6LS0PC9kaXY+CiAgICA8
ZGl2IGNsYXNzPSJjLXNlcCI+PC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0iIGlkPSJjLXBpbiI+
PHNwYW4gY2xhc3M9ImMtaWNvIj7imIU8L3NwYW4+5pS26JePPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJj
LWl0ZW0iIGlkPSJjLXRpdGxlIiBzdHlsZT0iZGlzcGxheTpub25lIj48c3BhbiBjbGFzcz0iYy1pY28i
PuKcjjwvc3Bhbj7orr7nva7moIfpopg8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImMtaXRlbSIgaWQ9ImMt
bWVyZ2UiIHN0eWxlPSJkaXNwbGF5Om5vbmUiPjxzcGFuIGNsYXNzPSJjLWljbyI+4qeJPC9zcGFuPuWQ
iOW5tjwvZGl2PgogICAgPGRpdiBjbGFzcz0iYy1pdGVtIiBpZD0iYy11bm1lcmdlIiBzdHlsZT0iZGlz
cGxheTpub25lIj48c3BhbiBjbGFzcz0iYy1pY28iPuKHhDwvc3Bhbj7lj5bmtojlkIjlubY8L2Rpdj4K
ICAgIDxkaXYgY2xhc3M9ImMtaXRlbSIgaWQ9ImMtdG9wIj48c3BhbiBjbGFzcz0iYy1pY28iPuKGkTwv
c3Bhbj7np7vliLDpobbpg6g8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImMtaXRlbSIgaWQ9ImMtY2xlYXIt
cGFzdGVkIiBzdHlsZT0iZGlzcGxheTpub25lIj48c3BhbiBjbGFzcz0iYy1pY28iPuKckzwvc3Bhbj7m
uIXpmaTnirbmgIE8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImMtc2VwIj48L2Rpdj4KICAgIDxkaXYgY2xh
c3M9ImMtaXRlbSBkYW5nZXIiIGlkPSJjLWRlbCI+PHNwYW4gY2xhc3M9ImMtaWNvIj7inJU8L3NwYW4+
5Yig6ZmkPC9kaXY+CjwvZGl2PgoKPGRpdiBpZD0iY2xyLWRsZyI+CiAgICA8ZGl2IGNsYXNzPSJjbHIt
Ym94IiByb2xlPSJkaWFsb2ciIGFyaWEtbW9kYWw9InRydWUiPgogICAgICAgIDxkaXYgY2xhc3M9ImNs
ci10aXRsZSIgaWQ9ImNsci10aXRsZSI+56Gu6K6k5riF56m677yfPC9kaXY+CiAgICAgICAgPGRpdiBj
bGFzcz0iY2xyLWRlc2MiIGlkPSJjbHItZGVzYyI+6buY6K6k5LuF5riF56m65b2T5aSp5YaF5a6544CC
PC9kaXY+CiAgICAgICAgPGxhYmVsIGNsYXNzPSJjbHItY2hlY2siIGZvcj0iY2xyLWFsbCI+CiAgICAg
ICAgICAgIDxpbnB1dCB0eXBlPSJjaGVja2JveCIgaWQ9ImNsci1hbGwiPgogICAgICAgICAgICA8c3Bh
bj7muIXnqbrmiYDmnIk8L3NwYW4+CiAgICAgICAgPC9sYWJlbD4KICAgICAgICA8ZGl2IGNsYXNzPSJj
bHItYnRucyI+CiAgICAgICAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBpZD0iY2xyLWNhbmNlbCI+
5Y+W5raIPC9idXR0b24+CiAgICAgICAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBpZD0iY2xyLW9r
Ij7muIXnqbo8L2J1dHRvbj4KICAgICAgICA8L2Rpdj4KICAgIDwvZGl2Pgo8L2Rpdj4KCjxkaXYgaWQ9
InRpdGxlLWRsZyI+CiAgICA8ZGl2IGNsYXNzPSJ0aXRsZS1ib3giIHJvbGU9ImRpYWxvZyIgYXJpYS1t
b2RhbD0idHJ1ZSI+CiAgICAgICAgPGRpdiBjbGFzcz0iY2xyLXRpdGxlIj7orr7nva7moIfpopg8L2Rp
dj4KICAgICAgICA8ZGl2IGNsYXNzPSJjbHItZGVzYyI+5qCH6aKY5Y+v6KKr5pCc57Si5om+5Yiw77yM
5LuF55So5LqO5pS26JeP5pW055CG44CCPC9kaXY+CiAgICAgICAgPGlucHV0IGlkPSJ0aXRsZS1pbnB1
dCIgdHlwZT0idGV4dCIgbWF4bGVuZ3RoPSI4MCIgcGxhY2Vob2xkZXI9Iue7mei/meadoeaUtuiXj+i1
t+S4quWQjeWtl+KApiIgYXV0b2NvbXBsZXRlPSJvZmYiIHNwZWxsY2hlY2s9ImZhbHNlIj4KICAgICAg
ICA8ZGl2IGNsYXNzPSJjbHItYnRucyI+CiAgICAgICAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBp
ZD0idGl0bGUtY2FuY2VsIj7lj5bmtog8L2J1dHRvbj4KICAgICAgICAgICAgPGJ1dHRvbiB0eXBlPSJi
dXR0b24iIGlkPSJ0aXRsZS1vayI+5L+d5a2YPC9idXR0b24+CiAgICAgICAgPC9kaXY+CiAgICA8L2Rp
dj4KPC9kaXY+CjxkaXYgaWQ9InBhdGgtdGlwIiBhcmlhLWhpZGRlbj0idHJ1ZSI+PC9kaXY+Cgo8c2Ny
aXB0PgovKiBza2VsLWZhaWxzYWZlOiBvbmx5IGlmIG1haW4gVUkgc2NyaXB0IG5ldmVyIGJvb3RlZCAq
LwooZnVuY3Rpb24oKXsKICBzZXRUaW1lb3V0KCgpID0+IHsKICAgIHRyeSB7CiAgICAgIGlmICh3aW5k
b3cuX191aUJvb3RlZCkgcmV0dXJuOwogICAgICB2YXIgYXBwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ2FwcCcpOwogICAgICBpZiAoYXBwKSBhcHAuY2xhc3NMaXN0LnJlbW92ZSgnYm9vdC1sb2FkaW5n
Jyk7CiAgICAgIHZhciBzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NrZWwnKTsKICAgICAgaWYg
KHMpIHMuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgdmFyIGUgPSBkb2N1bWVudC5nZXRFbGVt
ZW50QnlJZCgnZW1wdHknKTsKICAgICAgaWYgKGUgJiYgIWRvY3VtZW50LnF1ZXJ5U2VsZWN0b3IoJyNs
aXN0IC5pdG0nKSkgZS5jbGFzc0xpc3QuYWRkKCdvbicpOwogICAgfSBjYXRjaCAoZXJyKSB7fQogIH0s
IDMwMDApOwp9KSgpOwo8L3NjcmlwdD4KPHNjcmlwdD4KICAgIGxldCBhbGxDbGlwcyA9IFtdLCBjdXJU
YWIgPSAnYWxsJywgcXVlcnkgPSAnJywgY3R4Q2xpcCA9IG51bGwsIHNlbGVjdGVkSWQgPSAwLCBwaW5u
ZWRVSSA9IGZhbHNlOwogICAgY29uc3QgVEFCX09SREVSID0gWydhbGwnLCAndGV4dCcsICdpbWFnZScs
ICdmaWxlJywgJ3Bpbm5lZCddOwogICAgY29uc3Qgdmlld01lbSA9IG5ldyBNYXAoKTsKICAgIGZ1bmN0
aW9uIHZpZXdNZW1LZXkodGFiLCBxLCB0b2RheSkgewogICAgICAgIHJldHVybiBTdHJpbmcodGFiIHx8
ICdhbGwnKSArICdcdCcgKyBTdHJpbmcocSB8fCAnJykgKyAnXHQnICsgKHRvZGF5ID8gJzEnIDogJzAn
KTsKICAgIH0KICAgIGxldCB0YWJTd2l0Y2hBbmltRGlyID0gMDsKICAgIGxldCBtdWx0aUlkcyA9IFtd
OwogICAgbGV0IHRvZGF5T25seSA9IGZhbHNlOwogICAgbGV0IGRpc2tUb3RhbCA9IDA7CiAgICBsZXQg
bG9hZGluZ01vcmUgPSBmYWxzZTsKICAgIGxldCBib290TG9hZGluZyA9IHRydWU7CiAgICB3aW5kb3cu
X19kYXRhUmVhZHkgPSBmYWxzZTsKICAgIHdpbmRvdy5fX3VpQm9vdGVkID0gdHJ1ZTsKICAgIC8vIE9w
ZW4gcGFuZWwgd2l0aG91dCBwYXN0aW5nIOKGkiBhbHdheXMgbGFuZCBvbiBmaXJzdCBpdGVtIChhZnRl
ciBkYXRhIGFycml2ZXMpCiAgICBsZXQgc2VsZWN0Rmlyc3RPblNob3cgPSBmYWxzZTsKICAgIGxldCBs
YXN0UGFzdGVJZCA9IDA7CiAgICBsZXQgbGFzdFBhc3RlVGFiID0gJ2FsbCc7CiAgICBsZXQgbG9jYXRl
QWN0aXZlID0gZmFsc2U7CiAgICB0cnkgeyBsYXN0UGFzdGVJZCA9ICtsb2NhbFN0b3JhZ2UuZ2V0SXRl
bSgnY2xpcExhc3RQYXN0ZUlkJykgfHwgMDsgfSBjYXRjaCB7fQogICAgdHJ5IHsKICAgICAgICBjb25z
dCB0ID0gbG9jYWxTdG9yYWdlLmdldEl0ZW0oJ2NsaXBMYXN0UGFzdGVUYWInKSB8fCAnYWxsJzsKICAg
ICAgICBsYXN0UGFzdGVUYWIgPSBbJ2FsbCcsJ3RleHQnLCdpbWFnZScsJ2ZpbGUnLCdwaW5uZWQnXS5p
bmNsdWRlcyh0KSA/IHQgOiAnYWxsJzsKICAgIH0gY2F0Y2gge30KICAgIC8vIFNhbWUtb3JpZ2luIHVu
ZGVyIGNsaXB1aS5sb2NhbCAoQVBQX0hPU1Qg4oaSIENMSVBfVjFfRElSKS4gQ3Jvc3MtaG9zdCBjbGlw
cy5zdG9yZSBpcyB1bnJlbGlhYmxlLgogICAgY29uc3QgU1RPUkVfQkFTRSA9IChsb2NhdGlvbi5vcmln
aW4gJiYgbG9jYXRpb24ub3JpZ2luLmluZGV4T2YoJ2h0dHBzOi8vJykgPT09IDApCiAgICAgICAgPyAo
bG9jYXRpb24ub3JpZ2luLnJlcGxhY2UoL1wvJC8sICcnKSArICcvY2xpcHNfc3RvcmUvJykKICAgICAg
ICA6ICdodHRwczovL2NsaXB1aS5sb2NhbC9jbGlwc19zdG9yZS8nOwogICAgZnVuY3Rpb24gbWV0YUNl
bnRlckh0bWwoZXhwYW5kSW5uZXIpIHsKICAgICAgICBpZiAoZXhwYW5kSW5uZXIgPT0gbnVsbCB8fCBl
eHBhbmRJbm5lciA9PT0gZmFsc2UpCiAgICAgICAgICAgIHJldHVybiBgPHNwYW4gY2xhc3M9ImktbWV0
YS1jZW50ZXIiPjwvc3Bhbj5gOwogICAgICAgIHJldHVybiBgPHNwYW4gY2xhc3M9ImktbWV0YS1jZW50
ZXIiPjxidXR0b24gY2xhc3M9ImktZXhwYW5kLWJ0biR7ZXhwYW5kSW5uZXIub24gPyAnIG9uJyA6ICcn
fSIgdHlwZT0iYnV0dG9uIiB0aXRsZT0i5bGV5byAL+aUtui1tyI+JHtleHBhbmRJbm5lci5odG1sfTwv
YnV0dG9uPjwvc3Bhbj5gOwogICAgfQoKICAgIGZ1bmN0aW9uIHJlbWVtYmVyTGFzdFBhc3RlKGlkKSB7
CiAgICAgICAgbGFzdFBhc3RlSWQgPSAraWQgfHwgMDsKICAgICAgICBsYXN0UGFzdGVUYWIgPSBjdXJU
YWIgfHwgJ2FsbCc7CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgbG9jYWxTdG9yYWdlLnNldEl0ZW0o
J2NsaXBMYXN0UGFzdGVJZCcsIFN0cmluZyhsYXN0UGFzdGVJZCkpOwogICAgICAgICAgICBsb2NhbFN0
b3JhZ2Uuc2V0SXRlbSgnY2xpcExhc3RQYXN0ZVRhYicsIGxhc3RQYXN0ZVRhYik7CiAgICAgICAgfSBj
YXRjaCB7fQogICAgICAgIHVwZGF0ZUxvY2F0ZUJ0bigpOwogICAgfQogICAgZnVuY3Rpb24gdXBkYXRl
TG9jYXRlQnRuKCkgewogICAgICAgIGNvbnN0IGJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdi
dG4tbG9jYXRlJyk7CiAgICAgICAgaWYgKCFidG4pIHJldHVybjsKICAgICAgICBidG4uZGlzYWJsZWQg
PSAhbGFzdFBhc3RlSWQ7CiAgICAgICAgYnRuLmNsYXNzTGlzdC50b2dnbGUoJ2hhcy10YXJnZXQnLCAh
IWxhc3RQYXN0ZUlkKTsKICAgICAgICBidG4uY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCBsb2NhdGVBY3Rp
dmUgJiYgISFsYXN0UGFzdGVJZCk7CiAgICAgICAgYnRuLnRpdGxlID0gIWxhc3RQYXN0ZUlkCiAgICAg
ICAgICAgID8gJ+aaguaXoOS4iuasoeS9v+eUqOS9jee9ricKICAgICAgICAgICAgOiAobG9jYXRlQWN0
aXZlID8gJ+WPlua2iOWumuS9je+8jOWbnuWIsOesrOS4gOadoScgOiAn5a6a5L2N5Yiw5LiK5qyh5L2/
55So55qE5p2h55uuJyk7CiAgICB9CiAgICBmdW5jdGlvbiBzZWxlY3RGaXJzdEl0ZW0oKSB7CiAgICAg
ICAgbG9jYXRlQWN0aXZlID0gZmFsc2U7CiAgICAgICAgd2luZG93Ll9fcGVuZGluZ0p1bXBJZCA9IDA7
CiAgICAgICAgd2luZG93Ll9fanVtcExvYWRUcmllcyA9IDA7CiAgICAgICAgc2VsZWN0Rmlyc3RPblNo
b3cgPSBmYWxzZTsKICAgICAgICBjb25zdCB2aXMgPSB2aXNpYmxlTGlzdCgpOwogICAgICAgIGlmICgh
dmlzLmxlbmd0aCkgewogICAgICAgICAgICBzZWxlY3RlZElkID0gMDsKICAgICAgICAgICAgc3luY0l0
ZW1IaWdobGlnaHQoKTsKICAgICAgICAgICAgdXBkYXRlTG9jYXRlQnRuKCk7CiAgICAgICAgICAgIHJl
dHVybjsKICAgICAgICB9CiAgICAgICAgc2VsZWN0ZWRJZCA9IHZpc1swXS5pZDsKICAgICAgICByYW5n
ZUFuY2hvcklkID0gc2VsZWN0ZWRJZDsKICAgICAgICByYW5nZUFuY2hvckNsaWNrZWQgPSBmYWxzZTsK
ICAgICAgICBsaXN0RWwuc2Nyb2xsVG9wID0gMDsKICAgICAgICBzeW5jSXRlbUhpZ2hsaWdodCgpOwog
ICAgICAgIGNvbnN0IGVsID0gbGlzdEVsLnF1ZXJ5U2VsZWN0b3IoJy5pdG1bZGF0YS1pZD0iJyArIHNl
bGVjdGVkSWQgKyAnIl0nKTsKICAgICAgICBpZiAoZWwpIGVsLnNjcm9sbEludG9WaWV3KHsgYmxvY2s6
ICduZWFyZXN0JyB9KTsKICAgICAgICB1cGRhdGVMb2NhdGVCdG4oKTsKICAgIH0KICAgIGZ1bmN0aW9u
IGp1bXBUb0xhc3RQYXN0ZSgpIHsKICAgICAgICBpZiAoIWxhc3RQYXN0ZUlkKSByZXR1cm47CiAgICAg
ICAgLy8gQWxyZWFkeSBsb2NhdGVkIG9uIGxhc3QgcGFzdGUg4oaSIGNhbmNlbCBhbmQgc2VsZWN0IGZp
cnN0CiAgICAgICAgaWYgKGxvY2F0ZUFjdGl2ZSAmJiArc2VsZWN0ZWRJZCA9PT0gK2xhc3RQYXN0ZUlk
KSB7CiAgICAgICAgICAgIHNlbGVjdEZpcnN0SXRlbSgpOwogICAgICAgICAgICByZXR1cm47CiAgICAg
ICAgfQogICAgICAgIGxvY2F0ZUFjdGl2ZSA9IHRydWU7CiAgICAgICAgc2VsZWN0Rmlyc3RPblNob3cg
PSBmYWxzZTsKICAgICAgICAvLyBDbGVhciBmaWx0ZXJzIHNvIHRoZSBpdGVtIGlzIGZpbmRhYmxlIG9u
IHRoZSB0YWIgd2hlcmUgaXQgd2FzIHVzZWQKICAgICAgICBxdWVyeSA9ICcnOwogICAgICAgIHRvZGF5
T25seSA9IGZhbHNlOwogICAgICAgIHRyeSB7CiAgICAgICAgICAgIGNvbnN0IHNyY2ggPSBkb2N1bWVu
dC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoJyk7CiAgICAgICAgICAgIGNvbnN0IHNjbHIgPSBkb2N1bWVu
dC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLWNscicpOwogICAgICAgICAgICBjb25zdCB3cmFwID0gZG9j
dW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaC13cmFwJyk7CiAgICAgICAgICAgIGNvbnN0IGJ0blRv
ZGF5ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi10b2RheScpOwogICAgICAgICAgICBpZiAo
c3JjaCkgeyBzcmNoLnZhbHVlID0gJyc7IHNyY2guY2xhc3NMaXN0LnJlbW92ZSgnaGFzLXZhbCcpOyB9
CiAgICAgICAgICAgIGlmIChzY2xyKSBzY2xyLnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgICAgICAg
ICAgIGlmICh3cmFwKSB3cmFwLmNsYXNzTGlzdC5yZW1vdmUoJ29wZW4nKTsKICAgICAgICAgICAgaWYg
KGJ0blRvZGF5KSBidG5Ub2RheS5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgIH0gY2F0Y2gg
e30KICAgICAgICBjb25zdCB0YWIgPSBbJ2FsbCcsJ3RleHQnLCdpbWFnZScsJ2ZpbGUnLCdwaW5uZWQn
XS5pbmNsdWRlcyhsYXN0UGFzdGVUYWIpCiAgICAgICAgICAgID8gbGFzdFBhc3RlVGFiIDogJ2FsbCc7
CiAgICAgICAgY29uc3QgcHJldlRhYiA9IGN1clRhYjsKICAgICAgICBjdXJUYWIgPSB0YWI7CiAgICAg
ICAgbG9hZGluZ01vcmUgPSBmYWxzZTsKICAgICAgICBtYXJrVGFiKHRhYik7CiAgICAgICAgY2xlYXJN
dWx0aSgpOwogICAgICAgIHNlbGVjdGVkSWQgPSBsYXN0UGFzdGVJZDsKICAgICAgICB3aW5kb3cuX19w
ZW5kaW5nSnVtcElkID0gbGFzdFBhc3RlSWQ7CiAgICAgICAgd2luZG93Ll9fanVtcExvYWRUcmllcyA9
IDA7CiAgICAgICAgd2luZG93Ll9fanVtcEZlbGxCYWNrID0gZmFsc2U7CiAgICAgICAgdXBkYXRlTG9j
YXRlQnRuKCk7CiAgICAgICAgcmVxdWVzdFZpZXcoKTsKICAgIH0KCiAgICBmdW5jdGlvbiByZXF1ZXN0
VmlldygpIHsKICAgICAgICBjb25zdCB0YWIgPSBjdXJUYWIsIHEgPSBxdWVyeSwgdG9kYXkgPSB0b2Rh
eU9ubHkgPyAnMScgOiAnMCc7CiAgICAgICAgaWYgKHdpbmRvdy5fX3ZpZXdSYWYpIGNhbmNlbEFuaW1h
dGlvbkZyYW1lKHdpbmRvdy5fX3ZpZXdSYWYpOwogICAgICAgIHdpbmRvdy5fX3ZpZXdSYWYgPSByZXF1
ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4gewogICAgICAgICAgICB3aW5kb3cuX192aWV3UmFmID0gMDsK
ICAgICAgICAgICAgc2V0VGltZW91dCgoKSA9PiBhaGsoJ3NldFZpZXcnLCB0YWIsIHEsIHRvZGF5KSwg
MCk7CiAgICAgICAgfSk7CiAgICB9CiAgICBmdW5jdGlvbiByZXF1ZXN0TW9yZSgpIHsKICAgICAgICBp
ZiAobG9hZGluZ01vcmUpIHJldHVybjsKICAgICAgICBpZiAoZGlza1RvdGFsID4gMCAmJiBhbGxDbGlw
cy5sZW5ndGggPj0gZGlza1RvdGFsKSByZXR1cm47CiAgICAgICAgbG9hZGluZ01vcmUgPSB0cnVlOwog
ICAgICAgIHNldFRpbWVvdXQoKCkgPT4gYWhrKCdsb2FkTW9yZScpLCAwKTsKICAgIH0KICAgIGNvbnN0
IEVNUFRZX01TRyA9IHsKICAgICAgICBhbGw6ICAgICfmmoLml6DorrDlvZXvvIzlpI3liLblkI7oh6rl
iqjlh7rnjrAnLAogICAgICAgIHRleHQ6ICAgJ+aaguaXoOaWh+acrCcsCiAgICAgICAgaW1hZ2U6ICAn
5pqC5peg5Zu+5YOPJywKICAgICAgICBmaWxlOiAgICfmmoLml6Dmlofku7YnLAogICAgICAgIHBpbm5l
ZDogJ+aaguaXoOaUtuiXjycKICAgIH07CgogICAgZnVuY3Rpb24gYWhrSW52b2tlKG1ldGhvZCwgYXJn
cykgewogICAgICAgIHRyeSB7CiAgICAgICAgICAgIGNvbnN0IGhvc3QgPSBjaHJvbWUud2Vidmlldy5o
b3N0T2JqZWN0cy5zeW5jLmFoazsKICAgICAgICAgICAgaWYgKCFob3N0KSByZXR1cm47CiAgICAgICAg
ICAgIGxldCBjYWxsZWQgPSBmYWxzZTsKICAgICAgICAgICAgaWYgKHR5cGVvZiBob3N0LmNhbGwgPT09
ICdmdW5jdGlvbicpIHsKICAgICAgICAgICAgICAgIHRyeSB7IGhvc3QuY2FsbChtZXRob2QsIC4uLmFy
Z3MpOyBjYWxsZWQgPSB0cnVlOyB9IGNhdGNoIHt9CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYg
KCFjYWxsZWQgJiYgdHlwZW9mIGhvc3RbbWV0aG9kXSA9PT0gJ2Z1bmN0aW9uJykgewogICAgICAgICAg
ICAgICAgdHJ5IHsgaG9zdFttZXRob2RdKC4uLmFyZ3MpOyBjYWxsZWQgPSB0cnVlOyB9IGNhdGNoIHt9
CiAgICAgICAgICAgICAgICBpZiAoIWNhbGxlZCkgewogICAgICAgICAgICAgICAgICAgIHRyeSB7IGhv
c3RbbWV0aG9kXSguLi5hcmdzKTsgY2FsbGVkID0gdHJ1ZTsgfSBjYXRjaCB7fQogICAgICAgICAgICAg
ICAgfQogICAgICAgICAgICB9CiAgICAgICAgICAgIGlmICghY2FsbGVkICYmIGhvc3RbbWV0aG9kXSAh
PSBudWxsICYmIHR5cGVvZiBob3N0W21ldGhvZF0gIT09ICdmdW5jdGlvbicpIHsKICAgICAgICAgICAg
ICAgIHRyeSB7IHZvaWQgaG9zdFttZXRob2RdOyB9IGNhdGNoIHt9CiAgICAgICAgICAgIH0KICAgICAg
ICB9IGNhdGNoIChlKSB7IGNvbnNvbGUud2FybignYWhrLicgKyBtZXRob2QsIGUpOyB9CiAgICB9CiAg
ICBmdW5jdGlvbiBhaGsobWV0aG9kLCAuLi5hcmdzKSB7CiAgICAgICAgYWhrSW52b2tlKG1ldGhvZCwg
YXJncyk7CiAgICB9CiAgICBmdW5jdGlvbiBhaGtSZXQobWV0aG9kLCAuLi5hcmdzKSB7CiAgICAgICAg
dHJ5IHsKICAgICAgICAgICAgY29uc3QgaG9zdCA9IGNocm9tZS53ZWJ2aWV3Lmhvc3RPYmplY3RzLnN5
bmMuYWhrOwogICAgICAgICAgICBpZiAoIWhvc3QpIHJldHVybiBudWxsOwogICAgICAgICAgICBsZXQg
cmV0ID0gbnVsbDsKICAgICAgICAgICAgaWYgKHR5cGVvZiBob3N0LmNhbGwgPT09ICdmdW5jdGlvbicp
IHsKICAgICAgICAgICAgICAgIHRyeSB7IHJldCA9IGhvc3QuY2FsbChtZXRob2QsIC4uLmFyZ3MpOyB9
IGNhdGNoIHt9CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKHJldCA9PSBudWxsICYmIHR5cGVv
ZiBob3N0W21ldGhvZF0gPT09ICdmdW5jdGlvbicpIHsKICAgICAgICAgICAgICAgIHRyeSB7IHJldCA9
IGhvc3RbbWV0aG9kXSguLi5hcmdzKTsgfSBjYXRjaCB7fQogICAgICAgICAgICAgICAgaWYgKHJldCA9
PSBudWxsKSB7CiAgICAgICAgICAgICAgICAgICAgdHJ5IHsgcmV0ID0gaG9zdFttZXRob2RdKC4uLmFy
Z3MpOyB9IGNhdGNoIHt9CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgIH0KICAgICAgICAgICAg
aWYgKHJldCA9PSBudWxsICYmIGhvc3RbbWV0aG9kXSAhPSBudWxsICYmIHR5cGVvZiBob3N0W21ldGhv
ZF0gIT09ICdmdW5jdGlvbicpCiAgICAgICAgICAgICAgICByZXQgPSBob3N0W21ldGhvZF07CiAgICAg
ICAgICAgIGlmIChyZXQgPT0gbnVsbCkgcmV0dXJuIG51bGw7CiAgICAgICAgICAgIGlmICh0eXBlb2Yg
cmV0ID09PSAnc3RyaW5nJyB8fCB0eXBlb2YgcmV0ID09PSAnbnVtYmVyJyB8fCB0eXBlb2YgcmV0ID09
PSAnYm9vbGVhbicpCiAgICAgICAgICAgICAgICByZXR1cm4gcmV0OwogICAgICAgICAgICB0cnkgeyBy
ZXR1cm4gU3RyaW5nKHJldCk7IH0gY2F0Y2ggeyByZXR1cm4gcmV0OyB9CiAgICAgICAgfSBjYXRjaCAo
ZSkgeyBjb25zb2xlLndhcm4oJ2Foa1JldC4nICsgbWV0aG9kLCBlKTsgfQogICAgICAgIHJldHVybiBu
dWxsOwogICAgfQoKICAgIC8vIEVhcmx5IEFISyBfX3NldFRodW1iIGNhbiBhcnJpdmUgYmVmb3JlIERP
TSBub2RlcyBleGlzdCDigJQga2VlcCB1bnRpbCBiaW5kCiAgICBjb25zdCB0aHVtYkNhY2hlID0gbmV3
IE1hcCgpOwoKICAgIC8qKiBQcmVmZXIgZGF0YS1VUkwgKEFISyksIHRoZW4gdmlydHVhbC1ob3N0IGZp
bGUgVVJMICovCiAgICBmdW5jdGlvbiBiaW5kU3RvcmVUaHVtYihpbWcsIGZpbGUsIGlkLCBmYWxsYmFj
aykgewogICAgICAgIGltZy5kYXRhc2V0LnRodW1iSWQgPSBTdHJpbmcoaWQpOwogICAgICAgIGltZy5h
bHQgPSAnJzsKICAgICAgICBjb25zdCBmYWlsVGltZXIgPSBzZXRUaW1lb3V0KCgpID0+IHsKICAgICAg
ICAgICAgaWYgKCFpbWcuc3JjIHx8IGltZy5uYXR1cmFsV2lkdGggPCAxKQogICAgICAgICAgICAgICAg
aW1nLmFsdCA9ICfml6Dms5XliqDovb0nOwogICAgICAgIH0sIDEwMDAwKTsKICAgICAgICBpbWcuX2Zh
aWxUaW1lciA9IGZhaWxUaW1lcjsKICAgICAgICBjb25zdCBwcmV2TG9hZCA9IGltZy5vbmxvYWQ7CiAg
ICAgICAgaW1nLm9ubG9hZCA9IGUgPT4gewogICAgICAgICAgICBjbGVhclRpbWVvdXQoZmFpbFRpbWVy
KTsKICAgICAgICAgICAgaW1nLmFsdCA9ICcnOwogICAgICAgICAgICBpZiAodHlwZW9mIHByZXZMb2Fk
ID09PSAnZnVuY3Rpb24nKSBwcmV2TG9hZC5jYWxsKGltZywgZSk7CiAgICAgICAgfTsKICAgICAgICBp
bWcub25lcnJvciA9ICgpID0+IHsKICAgICAgICAgICAgaWYgKGZpbGUgJiYgIWltZy5kYXRhc2V0LnJl
dHJpZWQpIHsKICAgICAgICAgICAgICAgIGltZy5kYXRhc2V0LnJldHJpZWQgPSAnMSc7CiAgICAgICAg
ICAgICAgICBpbWcuc3JjID0gU1RPUkVfQkFTRSArIFN0cmluZyhmaWxlKS5zcGxpdCgnLycpLnBvcCgp
OwogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICB9CiAgICAgICAgICAgIGltZy5vbmVy
cm9yID0gbnVsbDsKICAgICAgICB9OwogICAgICAgIGNvbnN0IGNhY2hlZCA9IHRodW1iQ2FjaGUuZ2V0
KFN0cmluZyhpZCkpOwogICAgICAgIGNvbnN0IGRhdGFVcmwgPSAoZmFsbGJhY2sgJiYgU3RyaW5nKGZh
bGxiYWNrKS5zdGFydHNXaXRoKCdkYXRhOicpKQogICAgICAgICAgICA/IFN0cmluZyhmYWxsYmFjaykK
ICAgICAgICAgICAgOiAoY2FjaGVkICYmIFN0cmluZyhjYWNoZWQpLnN0YXJ0c1dpdGgoJ2RhdGE6Jykg
PyBTdHJpbmcoY2FjaGVkKSA6ICcnKTsKICAgICAgICBpZiAoZGF0YVVybCkgewogICAgICAgICAgICBp
bWcuc3JjID0gZGF0YVVybDsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBpZiAo
ZmlsZSkgewogICAgICAgICAgICBjb25zdCBiYXJlID0gU3RyaW5nKGZpbGUpLnNwbGl0KCcvJykucG9w
KCk7CiAgICAgICAgICAgIGltZy5zcmMgPSBTVE9SRV9CQVNFICsgYmFyZTsKICAgICAgICB9CiAgICB9
CgogICAgd2luZG93Ll9fc2V0VGh1bWIgPSAoaWQsIHVybCkgPT4gewogICAgICAgIGlmICghdXJsKSBy
ZXR1cm47CiAgICAgICAgY29uc3Qga2V5ID0gU3RyaW5nKGlkKTsKICAgICAgICB0aHVtYkNhY2hlLnNl
dChrZXksIHVybCk7CiAgICAgICAgbGV0IGhpdCA9IDA7CiAgICAgICAgZG9jdW1lbnQucXVlcnlTZWxl
Y3RvckFsbCgnLml0bVtkYXRhLWlkPSInICsga2V5ICsgJyJdIGltZy5pLXRodW1iJykuZm9yRWFjaChp
bWcgPT4gewogICAgICAgICAgICBpZiAoaW1nLl9mYWlsVGltZXIpIHRyeSB7IGNsZWFyVGltZW91dChp
bWcuX2ZhaWxUaW1lcik7IH0gY2F0Y2gge30KICAgICAgICAgICAgaW1nLm9uZXJyb3IgPSBudWxsOwog
ICAgICAgICAgICBpbWcuYWx0ID0gJyc7CiAgICAgICAgICAgIGltZy5zcmMgPSB1cmw7CiAgICAgICAg
ICAgIGhpdCsrOwogICAgICAgIH0pOwogICAgICAgIC8vIEFsc28gbWF0Y2ggbnVtZXJpYyBpZCBhdHRy
aWJ1dGUgcXVpcmtzCiAgICAgICAgaWYgKCFoaXQpIHsKICAgICAgICAgICAgZG9jdW1lbnQucXVlcnlT
ZWxlY3RvckFsbCgnaW1nLmktdGh1bWJbZGF0YS10aHVtYi1pZD0iJyArIGtleSArICciXScpLmZvckVh
Y2goaW1nID0+IHsKICAgICAgICAgICAgICAgIGlmIChpbWcuX2ZhaWxUaW1lcikgdHJ5IHsgY2xlYXJU
aW1lb3V0KGltZy5fZmFpbFRpbWVyKTsgfSBjYXRjaCB7fQogICAgICAgICAgICAgICAgaW1nLm9uZXJy
b3IgPSBudWxsOwogICAgICAgICAgICAgICAgaW1nLmFsdCA9ICcnOwogICAgICAgICAgICAgICAgaW1n
LnNyYyA9IHVybDsKICAgICAgICAgICAgfSk7CiAgICAgICAgfQogICAgfTsKCiAgICBmdW5jdGlvbiBp
c0RyYWdFeGNsdWRlKHQpIHsKICAgICAgICByZXR1cm4gISF0LmNsb3Nlc3QoJyNzZWFyY2gtd3JhcCwg
I2J0bi1zZWFyY2gsICNidG4tbG9jYXRlLCAjYnRuLXRvZGF5LCAjYnRuLXBpbiwgI2J0bi1jbHIsICNt
dWx0aS1jbnQsIC50YWIsIC5pdG0sICN0YWItYWN0aW9ucywgI2N0eCwgI2Nsci1kbGcsICNwYXRoLXRp
cCwgYnV0dG9uLCBpbnB1dCwgYScpOwogICAgfQogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Fw
cCcpLmFkZEV2ZW50TGlzdGVuZXIoJ21vdXNlZG93bicsIGUgPT4gewogICAgICAgIGlmIChlLmJ1dHRv
biAhPT0gMCkgcmV0dXJuOwogICAgICAgIGlmIChpc0RyYWdFeGNsdWRlKGUudGFyZ2V0KSkgcmV0dXJu
OwogICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICBhaGsoJ3N0YXJ0RHJhZycpOwogICAg
fSwgdHJ1ZSk7CgogICAgY29uc3QgaXNVcmwgID0gcyA9PiAvXmh0dHBzPzpcL1wvL2kudGVzdCgocyB8
fCAnJykudHJpbSgpKTsKCiAgICBmdW5jdGlvbiBhZ28oZGF0ZVN0cikgewogICAgICAgIHRyeSB7CiAg
ICAgICAgICAgIGNvbnN0IGQgPSBuZXcgRGF0ZShTdHJpbmcoZGF0ZVN0cikucmVwbGFjZSgnICcsICdU
JykpOwogICAgICAgICAgICBjb25zdCBzID0gKERhdGUubm93KCkgLSBkKSAvIDEwMDAgfCAwOwogICAg
ICAgICAgICBpZiAocyA8IDYwKSByZXR1cm4gJ+WImuWImic7CiAgICAgICAgICAgIGlmIChzIDwgMzYw
MCkgcmV0dXJuIChzIC8gNjAgfCAwKSArICcg5YiG6ZKf5YmNJzsKICAgICAgICAgICAgaWYgKHMgPCA4
NjQwMCkgcmV0dXJuIChzIC8gMzYwMCB8IDApICsgJyDlsI/ml7bliY0nOwogICAgICAgICAgICByZXR1
cm4gKHMgLyA4NjQwMCB8IDApICsgJyDlpKnliY0nOwogICAgICAgIH0gY2F0Y2ggeyByZXR1cm4gZGF0
ZVN0cjsgfQogICAgfQoKICAgIGZ1bmN0aW9uIG5vcm1UeXBlKHQpIHsKICAgICAgICB0ID0gU3RyaW5n
KHQgfHwgJycpLnRvTG93ZXJDYXNlKCk7CiAgICAgICAgaWYgKHQgPT09ICdpbWFnZScgfHwgdCA9PT0g
J2ltZycgfHwgdCA9PT0gJ2JpdG1hcCcpIHJldHVybiAnaW1hZ2UnOwogICAgICAgIGlmICh0ID09PSAn
ZmlsZScgIHx8IHQgPT09ICdmaWxlcycpIHJldHVybiAnZmlsZSc7CiAgICAgICAgcmV0dXJuICd0ZXh0
JzsKICAgIH0KICAgIGZ1bmN0aW9uIGlzUGlubmVkKGMpIHsKICAgICAgICByZXR1cm4gYy5waW5uZWQg
PT09IHRydWUgfHwgYy5waW5uZWQgPT09IDEgfHwgYy5waW5uZWQgPT09ICd0cnVlJyB8fCBjLnBpbm5l
ZCA9PT0gJzEnOwogICAgfQogICAgZnVuY3Rpb24gaXNQYXN0ZWQoYykgewogICAgICAgIHJldHVybiBj
LnBhc3RlZCA9PT0gdHJ1ZSB8fCBjLnBhc3RlZCA9PT0gMSB8fCBjLnBhc3RlZCA9PT0gJ3RydWUnIHx8
IGMucGFzdGVkID09PSAnMSc7CiAgICB9CgogICAgZnVuY3Rpb24gaXNNYXJrZG93bih0ZXh0KSB7CiAg
ICAgICAgaWYgKCF0ZXh0IHx8IHRleHQubGVuZ3RoIDwgNCkgcmV0dXJuIGZhbHNlOwogICAgICAgIHJl
dHVybiAvKD86XnxcbikjezEsNn0gfF5bLSorXSB8XCpcKlteKlxuXStcKlwqfF9fW15fXG5dK19ffCg/
Ol58XG4pPiB8YGBgfGBbXmBcbl0rYHxcW1teXF1dK1xdXChbXildK1wpfFx8LitcfC4rXHwvbS50ZXN0
KHRleHQpOwogICAgfQogICAgZnVuY3Rpb24gY2xpcFVzZXNNSWNvbihjKSB7CiAgICAgICAgaWYgKCFj
KSByZXR1cm4gZmFsc2U7CiAgICAgICAgaWYgKGMuaXNNZCA9PT0gdHJ1ZSB8fCBjLmlzTWQgPT09IDEg
fHwgYy5pc01kID09PSAndHJ1ZScgfHwgYy5pc01kID09PSAnMScpIHJldHVybiB0cnVlOwogICAgICAg
IGlmIChjLmlzUmljaCA9PT0gdHJ1ZSB8fCBjLmlzUmljaCA9PT0gMSB8fCBjLmlzUmljaCA9PT0gJ3Ry
dWUnIHx8IGMuaXNSaWNoID09PSAnMScpIHJldHVybiB0cnVlOwogICAgICAgIGNvbnN0IHQgPSBTdHJp
bmcoYy50eXBlIHx8ICcnKS50b0xvd2VyQ2FzZSgpOwogICAgICAgIGlmICh0ICYmIHQgIT09ICd0ZXh0
JyAmJiB0ICE9PSAnbGluaycpIHJldHVybiBmYWxzZTsKICAgICAgICByZXR1cm4gaXNNYXJrZG93bihj
LmRhdGEgfHwgYy5wcmV2aWV3IHx8ICcnKTsKICAgIH0KICAgIGZ1bmN0aW9uIGVzY0F0dHIocykgewog
ICAgICAgIHJldHVybiBTdHJpbmcocyB8fCAnJykKICAgICAgICAgICAgLnJlcGxhY2UoLyYvZywgJyZh
bXA7JykKICAgICAgICAgICAgLnJlcGxhY2UoLyIvZywgJyZxdW90OycpCiAgICAgICAgICAgIC5yZXBs
YWNlKC88L2csICcmbHQ7JykKICAgICAgICAgICAgLnJlcGxhY2UoLz4vZywgJyZndDsnKTsKICAgIH0K
CiAgICBmdW5jdGlvbiB0b2RheVByZWZpeCgpIHsKICAgICAgICBjb25zdCBkID0gbmV3IERhdGUoKTsK
ICAgICAgICBjb25zdCBwID0gbiA9PiBTdHJpbmcobikucGFkU3RhcnQoMiwgJzAnKTsKICAgICAgICBy
ZXR1cm4gZC5nZXRGdWxsWWVhcigpICsgJy0nICsgcChkLmdldE1vbnRoKCkgKyAxKSArICctJyArIHAo
ZC5nZXREYXRlKCkpOwogICAgfQogICAgZnVuY3Rpb24gaXNUb2RheUNsaXAoYykgewogICAgICAgIHJl
dHVybiBTdHJpbmcoYy50aW1lIHx8ICcnKS5zdGFydHNXaXRoKHRvZGF5UHJlZml4KCkpOwogICAgfQoK
ICAgIGZ1bmN0aW9uIGNsaXBIYXkoYykgewogICAgICAgIHJldHVybiBTdHJpbmcoYy5wcmV2aWV3IHx8
ICcnKSArICcgJyArIFN0cmluZyhjLmRhdGEgfHwgJycpICsgJyAnCiAgICAgICAgICAgICsgU3RyaW5n
KGMubGlua1RpdGxlIHx8ICcnKSArICcgJyArIFN0cmluZyhjLmZhdlRpdGxlIHx8ICcnKTsKICAgIH0K
ICAgIGZ1bmN0aW9uIGZpbHRlcihjbGlwcywgdGFiLCBxKSB7CiAgICAgICAgLy8gQUhLIOW3suaMieWF
s+mUruWtl+i/h+a7pOaXtuS4jeimgeWGjea7pO+8muWIl+ihqCBKU09OIOWPquaciSBwcmV2aWV377yM
5YWo5paH5ZG95Lit5Lya6KKr6K+v5p2A5oiQIDAg5p2hCiAgICAgICAgaWYgKHdpbmRvdy5fX2hvc3RG
aWx0ZXJlZCkgcmV0dXJuIGNsaXBzOwogICAgICAgIC8vIOWJjeerr+WFnOW6le+8muWFs+mUruWtl+W/
hemhu+WRveS4re+8iGF8YnxjID0gQU5E77yJ77yM6YG/5YWNIEFISyDmjqjkuobmnKrov4fmu6TliJfo
oagKICAgICAgICBjb25zdCB0ZXJtcyA9IHF1ZXJ5VGVybXMocSk7CiAgICAgICAgaWYgKCF0ZXJtcy5s
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
KG11bHRpSWRzLmxlbmd0aCA+IDApIHsKICAgICAgICAgICAgZWwudGV4dENvbnRlbnQgPSAn5bey6YCJ
ICcgKyBtdWx0aUlkcy5sZW5ndGg7CiAgICAgICAgICAgIGVsLmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAg
ICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgZWwuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAg
ICB9CiAgICAgICAgc3luY0l0ZW1IaWdobGlnaHQoKTsKICAgIH0KCiAgICBmdW5jdGlvbiBjbGVhck11
bHRpKHJlc3RvcmVUb0FuY2hvcikgewogICAgICAgIGNvbnN0IGJhY2tJZCA9ICtyYW5nZUFuY2hvcklk
IHx8IDA7CiAgICAgICAgbXVsdGlJZHMgPSBbXTsKICAgICAgICBpZiAocmVzdG9yZVRvQW5jaG9yICYm
IGJhY2tJZCkKICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IGJhY2tJZDsKICAgICAgICByYW5nZUFuY2hv
cklkID0gc2VsZWN0ZWRJZCB8fCAwOwogICAgICAgIHJhbmdlQW5jaG9yQ2xpY2tlZCA9IGZhbHNlOwog
ICAgICAgIHVwZGF0ZU11bHRpQmFkZ2UoKTsKICAgICAgICBpZiAocmVzdG9yZVRvQW5jaG9yICYmIHNl
bGVjdGVkSWQpIHsKICAgICAgICAgICAgY29uc3QgZWwgPSBsaXN0RWwucXVlcnlTZWxlY3RvcignLm1n
LXJvd1tkYXRhLWlkPSInICsgc2VsZWN0ZWRJZCArICciXScpCiAgICAgICAgICAgICAgICB8fCBsaXN0
RWwucXVlcnlTZWxlY3RvcignLml0bVtkYXRhLWlkPSInICsgc2VsZWN0ZWRJZCArICciXScpOwogICAg
ICAgICAgICBpZiAoZWwpIGVsLnNjcm9sbEludG9WaWV3KHsgYmxvY2s6ICduZWFyZXN0JyB9KTsKICAg
ICAgICB9CiAgICB9CgoKICAgIC8qIHNoaWZ0LXJhbmdlLXNlbGVjdC12MSAqLwogICAgbGV0IHJhbmdl
QW5jaG9ySWQgPSAwOwogICAgbGV0IHJhbmdlQW5jaG9yQ2xpY2tlZCA9IGZhbHNlOwogICAgZnVuY3Rp
b24gc2VsZWN0UmFuZ2VUbyhpZCkgewogICAgICAgIGlkID0gK2lkOwogICAgICAgIGNvbnN0IGxpc3Qg
PSAodHlwZW9mIG5hdkxpc3QgPT09ICdmdW5jdGlvbicgPyBuYXZMaXN0KCkgOiB2aXNpYmxlTGlzdCgp
KTsKICAgICAgICBjb25zdCBiID0gbGlzdC5maW5kSW5kZXgoYyA9PiArYy5pZCA9PT0gaWQpOwogICAg
ICAgIGlmIChiIDwgMCkgcmV0dXJuOwogICAgICAgIGxldCBhbmNob3IgPSArcmFuZ2VBbmNob3JJZDsK
ICAgICAgICBsZXQgYSA9IGxpc3QuZmluZEluZGV4KGMgPT4gK2MuaWQgPT09IGFuY2hvcik7CiAgICAg
ICAgaWYgKGEgPCAwKSB7CiAgICAgICAgICAgIGFuY2hvciA9ICtzZWxlY3RlZElkIHx8IGlkOwogICAg
ICAgICAgICBhID0gbGlzdC5maW5kSW5kZXgoYyA9PiArYy5pZCA9PT0gYW5jaG9yKTsKICAgICAgICB9
CiAgICAgICAgaWYgKGEgPCAwKSB7CiAgICAgICAgICAgIHJhbmdlQW5jaG9ySWQgPSBpZDsgc2VsZWN0
ZWRJZCA9IGlkOyBtdWx0aUlkcyA9IFtpZF07IHVwZGF0ZU11bHRpQmFkZ2UoKTsgcmV0dXJuOwogICAg
ICAgIH0KICAgICAgICBpZiAoIXJhbmdlQW5jaG9ySWQgfHwgbGlzdC5maW5kSW5kZXgoYyA9PiArYy5p
ZCA9PT0gK3JhbmdlQW5jaG9ySWQpIDwgMCkKICAgICAgICAgICAgcmFuZ2VBbmNob3JJZCA9IGxpc3Rb
YV0uaWQ7CiAgICAgICAgY29uc3QgbG8gPSBNYXRoLm1pbihhLCBiKSwgaGkgPSBNYXRoLm1heChhLCBi
KTsKICAgICAgICBtdWx0aUlkcyA9IFtdOwogICAgICAgIGZvciAobGV0IGkgPSBsbzsgaSA8PSBoaTsg
aSsrKSBtdWx0aUlkcy5wdXNoKCtsaXN0W2ldLmlkKTsKICAgICAgICBzZWxlY3RlZElkID0gaWQ7CiAg
ICAgICAgdXBkYXRlTXVsdGlCYWRnZSgpOwogICAgICAgIGNvbnN0IGVsID0gbGlzdEVsLnF1ZXJ5U2Vs
ZWN0b3IoJy5tZy1yb3dbZGF0YS1pZD0iJyArIHNlbGVjdGVkSWQgKyAnIl0nKSB8fCBsaXN0RWwucXVl
cnlTZWxlY3RvcignLml0bVtkYXRhLWlkPSInICsgc2VsZWN0ZWRJZCArICciXScpOwogICAgICAgIGlm
IChlbCkgZWwuc2Nyb2xsSW50b1ZpZXcoeyBibG9jazogJ25lYXJlc3QnIH0pOwogICAgfQogICAgZnVu
Y3Rpb24gc2hvd1NyY1RpcChhbmNob3IsIHRleHQpIHsKICAgICAgICB0ZXh0ID0gU3RyaW5nKHRleHQg
fHwgJycpLnRyaW0oKTsKICAgICAgICBpZiAoIXRleHQpIHJldHVybjsKICAgICAgICBsZXQgdGlwID0g
ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NyYy10aXAnKTsKICAgICAgICBpZiAoIXRpcCkgewogICAg
ICAgICAgICB0aXAgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgdGlw
LmlkID0gJ3NyYy10aXAnOwogICAgICAgICAgICBkb2N1bWVudC5ib2R5LmFwcGVuZENoaWxkKHRpcCk7
CiAgICAgICAgfQogICAgICAgIHRpcC50ZXh0Q29udGVudCA9IHRleHQ7CiAgICAgICAgdGlwLmNsYXNz
TGlzdC5hZGQoJ3Nob3cnKTsKICAgICAgICBjb25zdCByID0gYW5jaG9yLmdldEJvdW5kaW5nQ2xpZW50
UmVjdCgpOwogICAgICAgIGNvbnN0IHR3ID0gdGlwLm9mZnNldFdpZHRoIHx8IDE2MDsKICAgICAgICBj
b25zdCB0aCA9IHRpcC5vZmZzZXRIZWlnaHQgfHwgMjg7CiAgICAgICAgbGV0IGxlZnQgPSByLnJpZ2h0
IC0gdHc7CiAgICAgICAgbGV0IHRvcCA9IHIudG9wIC0gdGggLSA4OwogICAgICAgIGlmIChsZWZ0IDwg
OCkgbGVmdCA9IDg7CiAgICAgICAgaWYgKGxlZnQgKyB0dyA+IHdpbmRvdy5pbm5lcldpZHRoIC0gOCkg
bGVmdCA9IHdpbmRvdy5pbm5lcldpZHRoIC0gdHcgLSA4OwogICAgICAgIGlmICh0b3AgPCA4KSB0b3Ag
PSByLmJvdHRvbSArIDg7CiAgICAgICAgdGlwLnN0eWxlLmxlZnQgPSBsZWZ0ICsgJ3B4JzsKICAgICAg
ICB0aXAuc3R5bGUudG9wID0gdG9wICsgJ3B4JzsKICAgICAgICBjbGVhclRpbWVvdXQodGlwLl9oaWRl
VCk7CiAgICAgICAgdGlwLl9oaWRlVCA9IHNldFRpbWVvdXQoKCkgPT4gdGlwLmNsYXNzTGlzdC5yZW1v
dmUoJ3Nob3cnKSwgMjIwMCk7CiAgICB9CiAgICAvKiBpbWctaG92ZXItcHJldmlldy12OCAqLwogICAg
bGV0IF9faW1nSG92ZXJUaW1lciA9IDAsIF9faW1nSG92ZXJIaWRlVGltZXIgPSAwLCBfX2ltZ0hvdmVy
S2V5ID0gJyc7CiAgICBmdW5jdGlvbiBfX2ltZ0hvdmVyRW5zdXJlKCkgewogICAgICAgIGxldCBib3gg
PSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaW1nLWhvdmVyLXNpZGUnKTsKICAgICAgICBpZiAoIWJv
eCkgewogICAgICAgICAgICBib3ggPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsgYm94Lmlk
ID0gJ2ltZy1ob3Zlci1zaWRlJzsKICAgICAgICAgICAgY29uc3QgZnJhbWUgPSBkb2N1bWVudC5jcmVh
dGVFbGVtZW50KCdkaXYnKTsgZnJhbWUuY2xhc3NOYW1lID0gJ2locC1mcmFtZSc7CiAgICAgICAgICAg
IGNvbnN0IGltID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnaW1nJyk7IGltLmFsdCA9ICcnOwogICAg
ICAgICAgICBmcmFtZS5hcHBlbmRDaGlsZChpbSk7IGJveC5hcHBlbmRDaGlsZChmcmFtZSk7IGRvY3Vt
ZW50LmJvZHkuYXBwZW5kQ2hpbGQoYm94KTsKICAgICAgICB9CiAgICAgICAgbGV0IHN0ID0gZG9jdW1l
bnQuZ2V0RWxlbWVudEJ5SWQoJ2ltZy1ob3Zlci1zaWRlLWNzcycpOwogICAgICAgIGlmICghc3QpIHsg
c3QgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdzdHlsZScpOyBzdC5pZCA9ICdpbWctaG92ZXItc2lk
ZS1jc3MnOyBkb2N1bWVudC5oZWFkLmFwcGVuZENoaWxkKHN0KTsgfQogICAgICAgIHN0LnRleHRDb250
ZW50ID0gIiNpbWctaG92ZXItc2lkZXtwb3NpdGlvbjpmaXhlZDt6LWluZGV4OjEwMDAwMDtyaWdodDo2
cHg7dG9wOjUwJTt0cmFuc2Zvcm06dHJhbnNsYXRlWSgtNTAlKTtwb2ludGVyLWV2ZW50czpub25lO29w
YWNpdHk6MDt2aXNpYmlsaXR5OmhpZGRlbjttYXgtd2lkdGg6bWluKDYyMHB4LDkydncpO21heC1oZWln
aHQ6bWluKDkydmgsOTIwcHgpfSNpbWctaG92ZXItc2lkZS5zaG93e29wYWNpdHk6MTt2aXNpYmlsaXR5
OnZpc2libGV9I2ltZy1ob3Zlci1zaWRlIC5paHAtZnJhbWV7cGFkZGluZzozcHg7YmFja2dyb3VuZDoj
ZmZmO2JvcmRlcjoxcHggc29saWQgI0M1Q0REQztib3JkZXItcmFkaXVzOjJweDtib3gtc2hhZG93OjAg
NnB4IDE4cHggcmdiYSg0NCw0Niw1NCwuMTIpfSNpbWctaG92ZXItc2lkZSBpbWd7ZGlzcGxheTpibG9j
azttYXgtd2lkdGg6bWluKDYxMnB4LDkwdncpO21heC1oZWlnaHQ6bWluKDkwdmgsOTAwcHgpO3dpZHRo
OmF1dG87aGVpZ2h0OmF1dG87b2JqZWN0LWZpdDpjb250YWluO2JhY2tncm91bmQ6I2ZmZn0iOwogICAg
ICAgIHJldHVybiBib3g7CiAgICB9CiAgICB3aW5kb3cuX19pbWdIb3ZlclNob3cgPSBmdW5jdGlvbihm
aWxlLCBpZCkgewogICAgICAgIGNvbnN0IGJhcmUgPSBTdHJpbmcoZmlsZSB8fCAnJykuc3BsaXQoL1tc
XFxcL10vKS5wb3AoKTsgaWYgKCFiYXJlKSByZXR1cm47CiAgICAgICAgY29uc3QgYm94ID0gX19pbWdI
b3ZlckVuc3VyZSgpOyBjb25zdCBpbWcgPSBib3gucXVlcnlTZWxlY3RvcignaW1nJyk7IGlmICghaW1n
KSByZXR1cm47CiAgICAgICAgYm94LmNsYXNzTGlzdC5hZGQoJ3Nob3cnKTsKICAgICAgICBpbWcub25l
cnJvciA9ICgpID0+IHsKICAgICAgICAgICAgaW1nLm9uZXJyb3IgPSAoKSA9PiB7IGltZy5vbmVycm9y
ID0gbnVsbDsgdHJ5IHsgY29uc3QgYyA9IHRodW1iQ2FjaGUgJiYgdGh1bWJDYWNoZS5nZXQoU3RyaW5n
KGlkKSk7IGlmIChjKSBpbWcuc3JjID0gYzsgfSBjYXRjaCAoZSkge30gfTsKICAgICAgICAgICAgaW1n
LnNyYyA9IFNUT1JFX0JBU0UgKyAndGhfJyArIGJhcmUucmVwbGFjZSgvXC5bXi5dKyQvLCAnJykgKyAn
LmpwZyc7CiAgICAgICAgfTsKICAgICAgICBpbWcub25sb2FkID0gKCkgPT4geyBpbWcub25lcnJvciA9
IG51bGw7IH07CiAgICAgICAgaW1nLmRhdGFzZXQuYmFyZSA9IGJhcmU7IGltZy5zcmMgPSBTVE9SRV9C
QVNFICsgYmFyZTsKICAgIH07CiAgICB3aW5kb3cuX19pbWdIb3ZlckNsZWFyVWkgPSBmdW5jdGlvbigp
IHsKICAgICAgICBfX2ltZ0hvdmVyS2V5ID0gJyc7CiAgICAgICAgaWYgKF9faW1nSG92ZXJUaW1lcikg
eyBjbGVhclRpbWVvdXQoX19pbWdIb3ZlclRpbWVyKTsgX19pbWdIb3ZlclRpbWVyID0gMDsgfQogICAg
ICAgIGlmIChfX2ltZ0hvdmVySGlkZVRpbWVyKSB7IGNsZWFyVGltZW91dChfX2ltZ0hvdmVySGlkZVRp
bWVyKTsgX19pbWdIb3ZlckhpZGVUaW1lciA9IDA7IH0KICAgICAgICBjb25zdCBib3ggPSBkb2N1bWVu
dC5nZXRFbGVtZW50QnlJZCgnaW1nLWhvdmVyLXNpZGUnKTsgaWYgKGJveCkgYm94LmNsYXNzTGlzdC5y
ZW1vdmUoJ3Nob3cnKTsKICAgICAgICBjb25zdCBpbWcgPSBib3ggJiYgYm94LnF1ZXJ5U2VsZWN0b3Io
J2ltZycpOwogICAgICAgIGlmIChpbWcpIHsgaW1nLm9ubG9hZCA9IG51bGw7IGltZy5vbmVycm9yID0g
bnVsbDsgaW1nLnJlbW92ZUF0dHJpYnV0ZSgnc3JjJyk7IGRlbGV0ZSBpbWcuZGF0YXNldC5iYXJlOyB9
CiAgICB9OwogICAgd2luZG93Ll9faW1nSG92ZXJIaWRlID0gZnVuY3Rpb24oKSB7IHdpbmRvdy5fX2lt
Z0hvdmVyQ2xlYXJVaSgpOyB9OwogICAgZnVuY3Rpb24gYmluZEltZ0hvdmVyUHJldmlldyhlbCwgaWQs
IGZpbGUpIHsKICAgICAgICBpZiAoIWVsKSByZXR1cm47CiAgICAgICAgY29uc3QgYmFyZSA9IFN0cmlu
ZyhmaWxlIHx8ICcnKS5zcGxpdCgvW1xcXFwvXS8pLnBvcCgpOyBpZiAoIWJhcmUpIHJldHVybjsKICAg
ICAgICBjb25zdCBrZXkgPSBTdHJpbmcoaWQpICsgJ3wnICsgYmFyZTsKICAgICAgICBlbC5zdHlsZS5j
dXJzb3IgPSAnem9vbS1pbic7CiAgICAgICAgZWwuYWRkRXZlbnRMaXN0ZW5lcignbW91c2VlbnRlcics
ICgpID0+IHsKICAgICAgICAgICAgaWYgKF9faW1nSG92ZXJIaWRlVGltZXIpIHsgY2xlYXJUaW1lb3V0
KF9faW1nSG92ZXJIaWRlVGltZXIpOyBfX2ltZ0hvdmVySGlkZVRpbWVyID0gMDsgfQogICAgICAgICAg
ICBfX2ltZ0hvdmVyS2V5ID0ga2V5OwogICAgICAgICAgICBpZiAoX19pbWdIb3ZlclRpbWVyKSBjbGVh
clRpbWVvdXQoX19pbWdIb3ZlclRpbWVyKTsKICAgICAgICAgICAgX19pbWdIb3ZlclRpbWVyID0gc2V0
VGltZW91dCgoKSA9PiB7IGlmIChfX2ltZ0hvdmVyS2V5ID09PSBrZXkpIHRyeSB7IHdpbmRvdy5fX2lt
Z0hvdmVyU2hvdyhiYXJlLCBpZCk7IH0gY2F0Y2ggKGUpIHt9IH0sIDYwKTsKICAgICAgICB9KTsKICAg
ICAgICBlbC5hZGRFdmVudExpc3RlbmVyKCdtb3VzZWxlYXZlJywgKCkgPT4gewogICAgICAgICAgICBp
ZiAoX19pbWdIb3ZlclRpbWVyKSB7IGNsZWFyVGltZW91dChfX2ltZ0hvdmVyVGltZXIpOyBfX2ltZ0hv
dmVyVGltZXIgPSAwOyB9CiAgICAgICAgICAgIF9faW1nSG92ZXJIaWRlVGltZXIgPSBzZXRUaW1lb3V0
KCgpID0+IHsgaWYgKCFfX2ltZ0hvdmVyS2V5IHx8IF9faW1nSG92ZXJLZXkgPT09IGtleSkgd2luZG93
Ll9faW1nSG92ZXJIaWRlKCk7IH0sIDcwKTsKICAgICAgICB9KTsKICAgIH0KICAgIGZ1bmN0aW9uIGhh
bmRsZUl0ZW1DbGljayhlLCBjKSB7CiAgICAgICAgaWYgKGUuc2hpZnRLZXkpIHsKICAgICAgICAgICAg
ZS5wcmV2ZW50RGVmYXVsdCgpOyBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICBjb25zdCBs
aXN0ID0gKHR5cGVvZiBuYXZMaXN0ID09PSAnZnVuY3Rpb24nID8gbmF2TGlzdCgpIDogdmlzaWJsZUxp
c3QoKSk7CiAgICAgICAgICAgIGNvbnN0IGFuY2hvck9rID0gcmFuZ2VBbmNob3JDbGlja2VkICYmIHJh
bmdlQW5jaG9ySWQgJiYgbGlzdC5zb21lKHggPT4gK3guaWQgPT09ICtyYW5nZUFuY2hvcklkKTsKICAg
ICAgICAgICAgaWYgKCFhbmNob3JPaykgcmFuZ2VBbmNob3JJZCA9IHNlbGVjdGVkSWQgfHwgYy5pZDsK
ICAgICAgICAgICAgcmFuZ2VBbmNob3JDbGlja2VkID0gdHJ1ZTsKICAgICAgICAgICAgc2VsZWN0UmFu
Z2VUbyhjLmlkKTsKICAgICAgICAgICAgcmV0dXJuIHRydWU7CiAgICAgICAgfQogICAgICAgIGlmIChl
LmN0cmxLZXkgfHwgZS5tZXRhS2V5KSB7CiAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsgZS5z
dG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgdG9nZ2xlTXVsdGkoYy5pZCk7CiAgICAgICAgICAg
IHJldHVybiB0cnVlOwogICAgICAgIH0KICAgICAgICByYW5nZUFuY2hvcklkID0gYy5pZDsKICAgICAg
ICByYW5nZUFuY2hvckNsaWNrZWQgPSB0cnVlOwogICAgICAgIHJldHVybiBmYWxzZTsKICAgIH0KICAg
IGZ1bmN0aW9uIHRvZ2dsZU11bHRpKGlkKSB7CiAgICAgICAgaWQgPSAraWQ7CiAgICAgICAgY29uc3Qg
aSA9IG11bHRpSWRzLmluZGV4T2YoaWQpOwogICAgICAgIGlmIChpID49IDApIG11bHRpSWRzLnNwbGlj
ZShpLCAxKTsKICAgICAgICBlbHNlIG11bHRpSWRzLnB1c2goaWQpOwogICAgICAgIHNlbGVjdGVkSWQg
PSBpZDsKICAgICAgICByYW5nZUFuY2hvcklkID0gaWQ7CiAgICAgICAgcmFuZ2VBbmNob3JDbGlja2Vk
ID0gdHJ1ZTsKICAgICAgICB1cGRhdGVNdWx0aUJhZGdlKCk7CiAgICB9CgogICAgZnVuY3Rpb24gcmVu
ZGVyKCkgewogICAgICAgIGhpZGVQYXRoVGlwKCk7CgogICAgICAgIGNvbnN0IHZpc2libGUgPSB2aXNp
YmxlTGlzdCgpOwogICAgICAgIGNvbnN0IHBpbm5lZE4gPSBhbGxDbGlwcy5maWx0ZXIoYyA9PiBpc1Bp
bm5lZChjKSkubGVuZ3RoOwogICAgICAgIGNvbnN0IHBpbkNudCAgPSBkb2N1bWVudC5nZXRFbGVtZW50
QnlJZCgncGluLWNudCcpOwogICAgICAgIHBpbkNudC50ZXh0Q29udGVudCAgID0gcGlubmVkTjsKICAg
ICAgICBwaW5DbnQuc3R5bGUuZGlzcGxheSA9IHBpbm5lZE4gPyAnJyA6ICdub25lJzsKICAgICAgICBj
b25zdCBsb2FkZWQgPSBhbGxDbGlwcy5sZW5ndGg7CiAgICAgICAgY29uc3Qgc2hvd25Db3VudCA9IHZp
c2libGUubGVuZ3RoOwogICAgICAgIGNvbnN0IHNob3dUb3RhbCA9IGRpc2tUb3RhbCA+IDAgPyBkaXNr
VG90YWwgOiAobG9hZGVkIHx8IDApOwogICAgICAgIGNvbnN0IHFPbiA9IFN0cmluZyhxdWVyeSB8fCAn
JykudHJpbSgpLmxlbmd0aCA+IDA7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Jhci10
eHQnKS50ZXh0Q29udGVudCA9IHFPbgogICAgICAgICAgICA/IChzaG93bkNvdW50ICsgJyDmnaEnKQog
ICAgICAgICAgICA6IChkaXNrVG90YWwgPiBsb2FkZWQgPyAoc2hvd25Db3VudCArICcgLyAnICsgc2hv
d1RvdGFsICsgJyDmnaEnKSA6IChzaG93VG90YWwgKyAnIOadoScpKTsKICAgICAgICBkb2N1bWVudC5n
ZXRFbGVtZW50QnlJZCgnZW1wdHktdHh0JykudGV4dENvbnRlbnQgPSBFTVBUWV9NU0dbY3VyVGFiXSB8
fCBFTVBUWV9NU0cuYWxsOwoKICAgICAgICBjb25zdCBpZFNldCA9IG5ldyBTZXQoYWxsQ2xpcHMubWFw
KGMgPT4gK2MuaWQpKTsKICAgICAgICBtdWx0aUlkcyA9IG11bHRpSWRzLmZpbHRlcihpZCA9PiBpZFNl
dC5oYXMoaWQpKTsKICAgICAgICB1cGRhdGVNdWx0aUJhZGdlKCk7CgogICAgICAgIGNvbnN0IHNob3du
ID0gdmlzaWJsZTsKCiAgICAgICAgbGlzdEVsLnF1ZXJ5U2VsZWN0b3JBbGwoJy5pdG0sICNsaXN0LW1v
cmUnKS5mb3JFYWNoKGUgPT4gZS5yZW1vdmUoKSk7CiAgICAgICAgaWYgKGJvb3RMb2FkaW5nKSB7CiAg
ICAgICAgICAgIGlmIChza2VsRWwpIHNrZWxFbC5jbGFzc0xpc3QuYWRkKCdvbicpOwogICAgICAgICAg
ICBlbXB0eUVsLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgICAgIHVwZGF0ZVRvcEJ0bigp
OwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGlmIChza2VsRWwpIHNrZWxFbC5j
bGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAgIGlmICghdmlzaWJsZS5sZW5ndGgpIHsKICAgICAg
ICAgICAgaWYgKHNlbGVjdEZpcnN0T25TaG93KSB7CiAgICAgICAgICAgICAgICBzZWxlY3RGaXJzdE9u
U2hvdyA9IGZhbHNlOwogICAgICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IDA7CiAgICAgICAgICAgICAg
ICBjbGVhck11bHRpKCk7CiAgICAgICAgICAgICAgICBsaXN0RWwuc2Nyb2xsVG9wID0gMDsKICAgICAg
ICAgICAgfQogICAgICAgICAgICBlbXB0eUVsLmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAgICAgICAgICAg
IHVwZGF0ZVRvcEJ0bigpOwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGVtcHR5
RWwuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICBjb25zdCBmcmFnID0gZG9jdW1lbnQuY3Jl
YXRlRG9jdW1lbnRGcmFnbWVudCgpOwogICAgICAgIGNvbnN0IGJsb2NrcyA9IGJ1aWxkUGlubmVkQmxv
Y2tzKHNob3duKTsKICAgICAgICBsZXQgbnVtID0gMDsKICAgICAgICBibG9ja3MuZm9yRWFjaChiID0+
IHsKICAgICAgICAgICAgbnVtICs9IDE7CiAgICAgICAgICAgIGlmIChiLmtpbmQgPT09ICdncm91cCcg
JiYgYi5pdGVtcy5sZW5ndGggPiAxKQogICAgICAgICAgICAgICAgZnJhZy5hcHBlbmRDaGlsZChtYWtl
R3JvdXBJdGVtKGIuaXRlbXMsIG51bSkpOwogICAgICAgICAgICBlbHNlCiAgICAgICAgICAgICAgICBm
cmFnLmFwcGVuZENoaWxkKG1ha2VJdGVtKGIuaXRlbXNbMF0sIG51bSkpOwogICAgICAgIH0pOwogICAg
ICAgIGxpc3RFbC5hcHBlbmRDaGlsZChmcmFnKTsKICAgICAgICB1cGRhdGVNb3JlRm9vdGVyKGRpc2tU
b3RhbCk7CiAgICAgICAgaWYgKHNlbGVjdEZpcnN0T25TaG93KSB7CiAgICAgICAgICAgIHNlbGVjdEZp
cnN0T25TaG93ID0gZmFsc2U7CiAgICAgICAgICAgIHNlbGVjdGVkSWQgPSB2aXNpYmxlWzBdLmlkOwog
ICAgICAgICAgICBjbGVhck11bHRpKCk7CiAgICAgICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSAwOwog
ICAgICAgIH0gZWxzZSBpZiAoIXZpc2libGUuc29tZShjID0+IGMuaWQgPT0gc2VsZWN0ZWRJZCkpIHsK
ICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IHZpc2libGVbMF0uaWQ7CiAgICAgICAgICAgIHJhbmdlQW5j
aG9ySWQgPSBzZWxlY3RlZElkOwogICAgICAgICAgICByYW5nZUFuY2hvckNsaWNrZWQgPSBmYWxzZTsK
ICAgICAgICB9IGVsc2UgaWYgKCFyYW5nZUFuY2hvcklkKSB7CiAgICAgICAgICAgIHJhbmdlQW5jaG9y
SWQgPSBzZWxlY3RlZElkOwogICAgICAgIH0KICAgICAgICBzeW5jSXRlbUhpZ2hsaWdodCgpOwogICAg
ICAgIHVwZGF0ZVRvcEJ0bigpOwogICAgICAgIGlmICh3aW5kb3cuX19wZW5kaW5nSnVtcElkKSB7CiAg
ICAgICAgICAgIGNvbnN0IGppZCA9ICt3aW5kb3cuX19wZW5kaW5nSnVtcElkOwogICAgICAgICAgICBj
b25zdCBlbCA9IGxpc3RFbC5xdWVyeVNlbGVjdG9yKCcubWctcm93W2RhdGEtaWQ9IicgKyBqaWQgKyAn
Il0nKSB8fCBsaXN0RWwucXVlcnlTZWxlY3RvcignLml0bVtkYXRhLWlkPSInICsgamlkICsgJyJdJyk7
CiAgICAgICAgICAgIGlmIChlbCkgewogICAgICAgICAgICAgICAgd2luZG93Ll9fcGVuZGluZ0p1bXBJ
ZCA9IDA7CiAgICAgICAgICAgICAgICB3aW5kb3cuX19qdW1wTG9hZFRyaWVzID0gMDsKICAgICAgICAg
ICAgICAgIHNlbGVjdGVkSWQgPSBqaWQ7CiAgICAgICAgICAgICAgICByZXF1ZXN0QW5pbWF0aW9uRnJh
bWUoKCkgPT4gewogICAgICAgICAgICAgICAgICAgIGNvbnN0IG5vZGUgPSBsaXN0RWwucXVlcnlTZWxl
Y3RvcignLm1nLXJvd1tkYXRhLWlkPSInICsgamlkICsgJyJdJykgfHwgbGlzdEVsLnF1ZXJ5U2VsZWN0
b3IoJy5pdG1bZGF0YS1pZD0iJyArIGppZCArICciXScpOwogICAgICAgICAgICAgICAgICAgIGlmICgh
bm9kZSkgcmV0dXJuOwogICAgICAgICAgICAgICAgICAgIG5vZGUuc2Nyb2xsSW50b1ZpZXcoeyBibG9j
azogJ2NlbnRlcicgfSk7CiAgICAgICAgICAgICAgICAgICAgbm9kZS5jbGFzc0xpc3QuYWRkKCdqdW1w
LWZsYXNoJyk7CiAgICAgICAgICAgICAgICAgICAgc2V0VGltZW91dCgoKSA9PiBub2RlLmNsYXNzTGlz
dC5yZW1vdmUoJ2p1bXAtZmxhc2gnKSwgOTAwKTsKICAgICAgICAgICAgICAgICAgICBzeW5jSXRlbUhp
Z2hsaWdodCgpOwogICAgICAgICAgICAgICAgfSk7CiAgICAgICAgICAgIH0gZWxzZSBpZiAoYWxsQ2xp
cHMubGVuZ3RoIDwgZGlza1RvdGFsICYmICh3aW5kb3cuX19qdW1wTG9hZFRyaWVzIHx8IDApIDwgNDAp
IHsKICAgICAgICAgICAgICAgIHdpbmRvdy5fX2p1bXBMb2FkVHJpZXMgPSAod2luZG93Ll9fanVtcExv
YWRUcmllcyB8fCAwKSArIDE7CiAgICAgICAgICAgICAgICByZXF1ZXN0TW9yZSgpOwogICAgICAgICAg
ICB9IGVsc2UgaWYgKGN1clRhYiAhPT0gJ2FsbCcgJiYgIXdpbmRvdy5fX2p1bXBGZWxsQmFjaykgewog
ICAgICAgICAgICAgICAgLy8gSXRlbSBnb25lIGZyb20gdGhpcyB0YWIgKGUuZy4gdW5waW5uZWQpIOKA
lCBmYWxsIGJhY2sgdG8g5YWo6YOoIG9uY2UKICAgICAgICAgICAgICAgIHdpbmRvdy5fX2p1bXBGZWxs
QmFjayA9IHRydWU7CiAgICAgICAgICAgICAgICB3aW5kb3cuX19qdW1wTG9hZFRyaWVzID0gMDsKICAg
ICAgICAgICAgICAgIGN1clRhYiA9ICdhbGwnOwogICAgICAgICAgICAgICAgbWFya1RhYignYWxsJyk7
CiAgICAgICAgICAgICAgICByZXF1ZXN0VmlldygpOwogICAgICAgICAgICB9IGVsc2UgewogICAgICAg
ICAgICAgICAgd2luZG93Ll9fcGVuZGluZ0p1bXBJZCA9IDA7CiAgICAgICAgICAgICAgICB3aW5kb3cu
X19qdW1wTG9hZFRyaWVzID0gMDsKICAgICAgICAgICAgICAgIGlmIChhbGxDbGlwcy5zb21lKGMgPT4g
K2MuaWQgPT09IGppZCkpCiAgICAgICAgICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IGppZDsKICAgICAg
ICAgICAgICAgIHN5bmNJdGVtSGlnaGxpZ2h0KCk7CiAgICAgICAgICAgIH0KICAgICAgICB9CiAgICAg
ICAgcmVxdWVzdEFuaW1hdGlvbkZyYW1lKCgpID0+IHsKICAgICAgICAgICAgaWYgKGFsbENsaXBzLmxl
bmd0aCA8IGRpc2tUb3RhbAogICAgICAgICAgICAgICAgJiYgbGlzdEVsLnNjcm9sbEhlaWdodCA8PSBs
aXN0RWwuY2xpZW50SGVpZ2h0ICsgMjApCiAgICAgICAgICAgICAgICByZXF1ZXN0TW9yZSgpOwogICAg
ICAgICAgICBzY2hlZHVsZUZpbGVHb25lQ2hlY2soKTsKICAgICAgICB9KTsKICAgIH0KCiAgICBjb25z
dCBTVkcgPSB7CiAgICAgICAgdGV4dDogICBgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5v
bmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIiPjxwYXRoIGQ9Ik00IDdWNGgx
NnYzTTkgMjBoNk0xMiA0djE2Ii8+PC9zdmc+YCwKICAgICAgICBtZDogICAgIGA8c3ZnIHZpZXdCb3g9
IjAgMCAyNCAyNCIgZmlsbD0iY3VycmVudENvbG9yIj48dGV4dCB4PSIxMiIgeT0iMTciIHRleHQtYW5j
aG9yPSJtaWRkbGUiIGZvbnQtc2l6ZT0iMTUiIGZvbnQtd2VpZ2h0PSI4MDAiIGZvbnQtZmFtaWx5PSJT
ZWdvZSBVSSxNaWNyb3NvZnQgWWFIZWksc2Fucy1zZXJpZiI+TTwvdGV4dD48L3N2Zz5gLAogICAgICAg
IGltYWdlOiAgYDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJl
bnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxyZWN0IHg9IjMiIHk9IjUiIHdpZHRoPSIxOCIgaGVp
Z2h0PSIxNCIgcng9IjIiLz48Y2lyY2xlIGN4PSI4LjUiIGN5PSIxMCIgcj0iMS41IiBmaWxsPSJjdXJy
ZW50Q29sb3IiIHN0cm9rZT0ibm9uZSIvPjxwYXRoIGQ9Ik0zIDE2bDUtNSA0IDQgMy0zIDYgNiIvPjwv
c3ZnPmAsCiAgICAgICAgdmlkZW86ICBgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUi
IHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCI+PHJlY3QgeD0iMyIgeT0iNiIg
d2lkdGg9IjE0IiBoZWlnaHQ9IjEyIiByeD0iMiIvPjxwYXRoIGQ9Ik0xNyA5LjVsNC0yLjV2MTBsLTQt
Mi41VjkuNXoiIGZpbGw9ImN1cnJlbnRDb2xvciIgc3Ryb2tlPSJub25lIi8+PHBhdGggZD0iTTguNSAx
MC4ydjMuNmwzLjItMS44LTMuMi0xLjh6IiBmaWxsPSJjdXJyZW50Q29sb3IiIHN0cm9rZT0ibm9uZSIv
Pjwvc3ZnPmAsCiAgICAgICAgZm9sZGVyOiBgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9ImN1
cnJlbnRDb2xvciI+PHBhdGggZD0iTTEwIDRINGMtMS4xIDAtMiAuOS0yIDJ2MTJjMCAxLjEuOSAyIDIg
MmgxNmMxLjEgMCAyLS45IDItMlY4YzAtMS4xLS45LTItMi0yaC04bC0yLTJ6Ii8+PC9zdmc+YCwKICAg
ICAgICB6aXA6ICAgIGA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJj
dXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44Ij48cGF0aCBkPSJNNiAzaDlsNSA1djEzYTEgMSAw
IDAgMS0xIDFINmExIDEgMCAwIDEtMS0xVjRhMSAxIDAgMCAxIDEtMXoiLz48cGF0aCBkPSJNMTQgM3Y2
aDYiLz48L3N2Zz5gLAogICAgICAgIGFoazogICAgYDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxs
PSJjdXJyZW50Q29sb3IiPjx0ZXh0IHg9IjEyIiB5PSIxNyIgdGV4dC1hbmNob3I9Im1pZGRsZSIgZm9u
dC1zaXplPSIxNCIgZm9udC13ZWlnaHQ9IjcwMCI+SDwvdGV4dD48L3N2Zz5gLAogICAgICAgIGxuazog
ICAgYDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xv
ciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxwYXRoIGQ9Ik0xMCAxM2E1IDUgMCAwIDAgNy4wNyAwbDIuMTIt
Mi4xMmE1IDUgMCAwIDAtNy4wNy03LjA3TDExIDUiLz48cGF0aCBkPSJNMTQgMTFhNSA1IDAgMCAwLTcu
MDcgMEw0LjggMTMuMTJhNSA1IDAgMSAwIDcuMDcgNy4wN0wxMyAxOSIvPjwvc3ZnPmAsCiAgICAgICAg
ZG9jOiAgICBgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVu
dENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCI+PHBhdGggZD0iTTcgM2g3bDUgNXYxM2ExIDEgMCAwIDEt
MSAxSDdhMSAxIDAgMCAxLTEtMVY0YTEgMSAwIDAgMSAxLTF6Ii8+PHBhdGggZD0iTTE0IDN2Nmg2Ii8+
PC9zdmc+YCwKICAgICAgICBtdWx0aTogIGA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9u
ZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44Ij48cmVjdCB4PSI3IiB5PSI3
IiB3aWR0aD0iMTIiIGhlaWdodD0iMTQiIHJ4PSIxLjUiLz48cGF0aCBkPSJNNSAxN1Y1YTEgMSAwIDAg
MSAxLTFoMTAiLz48L3N2Zz5gCiAgICB9OwoKICAgIGZ1bmN0aW9uIGZpbGVFeHQocGF0aCkgewogICAg
ICAgIGNvbnN0IGJhc2UgPSBTdHJpbmcocGF0aCB8fCAnJykuc3BsaXQoL1tcXC9dLykucG9wKCkgfHwg
Jyc7CiAgICAgICAgY29uc3QgaSA9IGJhc2UubGFzdEluZGV4T2YoJy4nKTsKICAgICAgICByZXR1cm4g
aSA+IDAgPyBiYXNlLnNsaWNlKGkgKyAxKS50b0xvd2VyQ2FzZSgpIDogJyc7CiAgICB9CiAgICBjb25z
dCBpc0ltYWdlRXh0ID0gZSA9PiBbJ3BuZycsJ2pwZycsJ2pwZWcnLCdnaWYnLCd3ZWJwJywnYm1wJywn
aWNvJywndGlmJywndGlmZicsJ3N2ZyddLmluY2x1ZGVzKGUpOwogICAgY29uc3QgaXNWaWRlb0V4dCA9
IGUgPT4gWydtcDQnLCdta3YnLCdhdmknLCdtb3YnLCd3bXYnLCdmbHYnLCd3ZWJtJywnbTR2JywnbXBl
ZycsJ21wZycsJ3RzJywnbTJ0cycsJzNncCcsJ3JtJywncm12YiddLmluY2x1ZGVzKGUpOwogICAgY29u
c3QgaXNaaXBFeHQgICA9IGUgPT4gWyd6aXAnLCdyYXInLCc3eicsJ3RhcicsJ2d6JywnYnoyJ10uaW5j
bHVkZXMoZSk7CgogICAgZnVuY3Rpb24gaWNvbkZvckZpbGVzKGZpbGVzKSB7CiAgICAgICAgaWYgKCFm
aWxlcy5sZW5ndGgpICAgIHJldHVybiB7IGNsczogJ2ZpbGUgZnQtZG9jJywgc3ZnOiBTVkcuZG9jIH07
CiAgICAgICAgaWYgKGZpbGVzLmxlbmd0aCA+IDEpIHJldHVybiB7IGNsczogJ2ZpbGUgZnQtbG5rJywg
c3ZnOiBTVkcubXVsdGkgfTsKICAgICAgICBjb25zdCBleHQgPSBmaWxlRXh0KGZpbGVzWzBdKTsKICAg
ICAgICBpZiAoIWV4dCkgICAgICAgICAgICAgIHJldHVybiB7IGNsczogJ2ZpbGUgZnQtZGlyJywgc3Zn
OiBTVkcuZm9sZGVyIH07CiAgICAgICAgaWYgKGlzSW1hZ2VFeHQoZXh0KSkgICByZXR1cm4geyBjbHM6
ICdmaWxlIGZ0LWltZycsIHN2ZzogU1ZHLmltYWdlIH07CiAgICAgICAgaWYgKGlzVmlkZW9FeHQoZXh0
KSkgICByZXR1cm4geyBjbHM6ICdmaWxlIGZ0LXZpZCcsIHN2ZzogKFNWRy52aWRlbyB8fCBTVkcuZG9j
KSB9OwogICAgICAgIGlmIChpc1ppcEV4dChleHQpKSAgICAgcmV0dXJuIHsgY2xzOiAnZmlsZSBmdC16
aXAnLCBzdmc6IFNWRy56aXAgfTsKICAgICAgICBpZiAoZXh0ID09PSAnYWhrJykgICAgIHJldHVybiB7
IGNsczogJ2ZpbGUgZnQtYWhrJywgc3ZnOiBTVkcuYWhrIH07CiAgICAgICAgaWYgKGV4dCA9PT0gJ2xu
aycpICAgICByZXR1cm4geyBjbHM6ICdmaWxlIGZ0LWxuaycsIHN2ZzogU1ZHLmxuayB9OwogICAgICAg
IHJldHVybiB7IGNsczogJ2ZpbGUgZnQtZG9jJywgc3ZnOiBTVkcuZG9jIH07CiAgICB9CgogICAgZnVu
Y3Rpb24gc3JjV2luTGFiZWwoYykgewogICAgICAgIGNvbnN0IHQgPSBTdHJpbmcoYyAmJiBjLnNyY1Rp
dGxlIHx8ICcnKS50cmltKCk7CiAgICAgICAgaWYgKHQpIHJldHVybiB0OwogICAgICAgIHJldHVybiBT
dHJpbmcoYyAmJiBjLnNyY0V4ZSB8fCAnJykucmVwbGFjZSgvXC5leGUkL2ksICcnKTsKICAgIH0KICAg
IGZ1bmN0aW9uIHNyY1RpdGxlSHRtbChjKSB7CiAgICAgICAgY29uc3QgdCA9IHNyY1dpbkxhYmVsKGMp
OwogICAgICAgIGlmICghdCkgcmV0dXJuICcnOwogICAgICAgIHJldHVybiAnPHNwYW4gY2xhc3M9Imkt
c3JjLXRpdGxlIiB0aXRsZT0iJyArIGVzY0h0bWwodCkgKyAnIj4nICsgZXNjSHRtbCh0KSArICc8L3Nw
YW4+JzsKICAgIH0KCiAgICBmdW5jdGlvbiBmYXZHcm91cE9mKGMpIHsKICAgICAgICByZXR1cm4gU3Ry
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
c2V0LmlkID0gYy5pZDsKCiAgICAgICAgY29uc3QgaWNvICA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQo
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
aS1tZXRhLXJpZ2h0Ij4ke3NyY1RpdGxlSHRtbChjKX0ke2Mud2lkdGggPyBgPHNwYW4gY2xhc3M9Imkt
dGFnIj4ke2Mud2lkdGh9w5cke2MuaGVpZ2h0fSBweDwvc3Bhbj5gIDogJyd9PC9kaXY+YDsKICAgICAg
ICAgICAgYm9keS5hcHBlbmRDaGlsZCh3cmFwKTsKICAgICAgICAgICAgYm9keS5hcHBlbmRDaGlsZCht
ZXRhKTsKICAgICAgICB9IGVsc2UgaWYgKHR5cGUgPT09ICdmaWxlJykgewogICAgICAgICAgICBjb25z
dCBmaWxlcyA9IFN0cmluZyhjLnByZXZpZXcgfHwgYy5kYXRhIHx8ICcnKS5zcGxpdCgvXHI/XG4vKS5m
aWx0ZXIoQm9vbGVhbik7CiAgICAgICAgICAgIGNvbnN0IGltYWdlUGF0aHMgPSBmaWxlcy5maWx0ZXIo
ZiA9PiBpc0ltYWdlRXh0KGZpbGVFeHQoZikpKTsKICAgICAgICAgICAgY29uc3QgaWMgICAgPSBpY29u
Rm9yRmlsZXMoZmlsZXMpOwogICAgICAgICAgICBpY28uY2xhc3NOYW1lID0gJ2ktaWNvICcgKyBpYy5j
bHM7CiAgICAgICAgICAgIGljby5pbm5lckhUTUwgPSBpYy5zdmc7CgogICAgICAgICAgICBsZXQgdGh1
bWJGaWxlID0gU3RyaW5nKGMuaW1nRmlsZSB8fCAnJyk7CiAgICAgICAgICAgIC8qIGVuc3VyZUZpbGVJ
bWcgZGVmZXJyZWQ6IGF2b2lkIHN5bmMgZnJlZXplIG9uIGZpbGUgdGFiICovCgogICAgICAgICAgICAv
LyBJbWFnZS1mb3JtYXQgZmlsZXM6IHNhbWUgdGh1bWJuYWlsIHJ1bGVzIGFzIHNjcmVlbnNob3QgY2xp
cHMKICAgICAgICAgICAgaWYgKHRodW1iRmlsZSB8fCBpbWFnZVBhdGhzLmxlbmd0aCkgewogICAgICAg
ICAgICAgICAgY29uc3Qgd3JhcCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAg
ICAgICAgICAgd3JhcC5jbGFzc05hbWUgPSAnaS10aHVtYi13cmFwJzsKICAgICAgICAgICAgICAgIGNv
bnN0IGltZyAgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdpbWcnKTsKICAgICAgICAgICAgICAgIGlt
Zy5jbGFzc05hbWUgPSAnaS10aHVtYic7CiAgICAgICAgICAgICAgICBpbWcuYWx0ID0gJyc7CiAgICAg
ICAgICAgICAgICBpbWcub25sb2FkID0gKCkgPT4gewogICAgICAgICAgICAgICAgICAgIGNvbnN0IG13
ID0gd3JhcC5jbGllbnRXaWR0aCB8fCAzMDA7CiAgICAgICAgICAgICAgICAgICAgY29uc3QgbncgPSBp
bWcubmF0dXJhbFdpZHRoICB8fCAwOwogICAgICAgICAgICAgICAgICAgIGNvbnN0IG5oID0gaW1nLm5h
dHVyYWxIZWlnaHQgfHwgMDsKICAgICAgICAgICAgICAgICAgICBpZiAoIW53IHx8ICFuaCkgcmV0dXJu
OwogICAgICAgICAgICAgICAgICAgIGNvbnN0IHNjYWxlID0gTWF0aC5taW4oMSwgMTgwIC8gbmgsIG13
IC8gbncpOwogICAgICAgICAgICAgICAgICAgIGltZy5zdHlsZS53aWR0aCAgPSBNYXRoLnJvdW5kKG53
ICogc2NhbGUpICsgJ3B4JzsKICAgICAgICAgICAgICAgICAgICBpbWcuc3R5bGUuaGVpZ2h0ID0gTWF0
aC5yb3VuZChuaCAqIHNjYWxlKSArICdweCc7CiAgICAgICAgICAgICAgICB9OwogICAgICAgICAgICAv
KiBlbnN1cmVGaWxlSW1nIGRlZmVycmVkOiBhdm9pZCBzeW5jIGZyZWV6ZSBvbiBmaWxlIHRhYiAqLwog
ICAgICAgICAgICAgICAgYmluZFN0b3JlVGh1bWIoaW1nLCB0aHVtYkZpbGUsIGMuaWQsICcnKTsKICAg
ICAgICAgICAgICAgIHdyYXAuYXBwZW5kQ2hpbGQoaW1nKTsKICAgICAgICAgICAgICAgIGJvZHkuYXBw
ZW5kQ2hpbGQod3JhcCk7CiAgICAgICAgICAgIH0KCiAgICAgICAgICAgIGNvbnN0IG5hbWUgPSBkb2N1
bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgbmFtZS5jbGFzc05hbWUgID0gJ2kt
bmFtZSc7CiAgICAgICAgICAgIHNldEhsVGV4dChuYW1lLCBmaWxlcy5tYXAoZiA9PiBmLnNwbGl0KC9b
XFwvXS8pLnBvcCgpKS5qb2luKCdcbicpIHx8ICco5paH5Lu2KScpOwoKICAgICAgICAgICAgZWwuX2Zp
bGVQYXRocyA9IGZpbGVzOwoKICAgICAgICAgICAgY29uc3QgZGV0YWlsID0gZG9jdW1lbnQuY3JlYXRl
RWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIGRldGFpbC5jbGFzc05hbWUgPSAnaS1maWxlLWRldGFp
bCc7CgogICAgICAgICAgICBjb25zdCBtZXRhID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7
CiAgICAgICAgICAgIG1ldGEuY2xhc3NOYW1lID0gJ2ktbWV0YSc7CiAgICAgICAgICAgIGxldCByaWdo
dCA9IHNyY1RpdGxlSHRtbChjKTsKICAgICAgICAgICAgcmlnaHQgKz0gYDxzcGFuIGNsYXNzPSJpLXRh
ZyI+JHtjLmZpbGVDb3VudCB8fCBmaWxlcy5sZW5ndGggfHwgMX0g5Liq5paH5Lu2PC9zcGFuPmA7CiAg
ICAgICAgICAgIGlmICgodGh1bWJGaWxlIHx8IGltYWdlUGF0aHMubGVuZ3RoKSAmJiBjLndpZHRoKQog
ICAgICAgICAgICAgICAgcmlnaHQgKz0gYDxzcGFuIGNsYXNzPSJpLXRhZyI+JHtjLndpZHRofcOXJHtj
LmhlaWdodH0gcHg8L3NwYW4+YDsKICAgICAgICAgICAgY29uc3QgZXhwYW5kSHRtbCA9CiAgICAgICAg
ICAgICAgICBgPHN2ZyB2aWV3Qm94PSIwIDAgMTYgMTYiIHdpZHRoPSIxMCIgaGVpZ2h0PSIxMCIgZmls
bD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44IiBzdHJva2UtbGlu
ZWNhcD0icm91bmQiPmAgKwogICAgICAgICAgICAgICAgYDxwb2x5bGluZSBwb2ludHM9IjQgNiA4IDEw
IDEyIDYiLz48L3N2Zz5gOwogICAgICAgICAgICBjb25zdCBjb2xsYXBzZUh0bWwgPQogICAgICAgICAg
ICAgICAgYDxzdmcgdmlld0JveD0iMCAwIDE2IDE2IiB3aWR0aD0iMTAiIGhlaWdodD0iMTAiIGZpbGw9
Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCIgc3Ryb2tlLWxpbmVj
YXA9InJvdW5kIj5gICsKICAgICAgICAgICAgICAgIGA8cG9seWxpbmUgcG9pbnRzPSI0IDEwIDggNiAx
MiAxMCIvPjwvc3ZnPmA7CiAgICAgICAgICAgIG1ldGEuaW5uZXJIVE1MID0KICAgICAgICAgICAgICAg
IGA8c3BhbiBjbGFzcz0iaS10aW1lIj4ke2FnbyhjLnRpbWUpfTwvc3Bhbj5gICsKICAgICAgICAgICAg
ICAgIG1ldGFDZW50ZXJIdG1sKHsgb246IHRydWUsIGh0bWw6IGV4cGFuZEh0bWwgfSkgKwogICAgICAg
ICAgICAgICAgYDxkaXYgY2xhc3M9ImktbWV0YS1yaWdodCI+JHtyaWdodH08L2Rpdj5gOwoKICAgICAg
ICAgICAgY29uc3QgZXhwQnRuID0gbWV0YS5xdWVyeVNlbGVjdG9yKCcuaS1leHBhbmQtYnRuJyk7CiAg
ICAgICAgICAgIGxldCBkZXRhaWxCdWlsdCA9IGZhbHNlOwogICAgICAgICAgICBleHBCdG4ub25jbGlj
ayA9IGUgPT4gewogICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICAg
ICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgIGNvbnN0IG9wZW4gPSAhZGV0YWls
LmNsYXNzTGlzdC5jb250YWlucygnb24nKTsKICAgICAgICAgICAgICAgIGlmIChvcGVuICYmICFkZXRh
aWxCdWlsdCkgewogICAgICAgICAgICAgICAgICAgIGNvbnN0IHBhdGhSb3dzID0gZWwuX3BhdGhSb3dz
IHx8IGNoZWNrRmlsZVBhdGhzKGVsLl9maWxlUGF0aHMgfHwgZmlsZXMpOwogICAgICAgICAgICAgICAg
ICAgIGZpbGxGaWxlRGV0YWlsUGFuZWwoZGV0YWlsLCBwYXRoUm93cyk7CiAgICAgICAgICAgICAgICAg
ICAgZGV0YWlsQnVpbHQgPSB0cnVlOwogICAgICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgZGV0
YWlsLmNsYXNzTGlzdC50b2dnbGUoJ29uJywgb3Blbik7CiAgICAgICAgICAgICAgICBleHBCdG4uaW5u
ZXJIVE1MID0gb3BlbiA/IGNvbGxhcHNlSHRtbCA6IGV4cGFuZEh0bWw7CiAgICAgICAgICAgIH07Cgog
ICAgICAgICAgICBib2R5LmFwcGVuZENoaWxkKG5hbWUpOwogICAgICAgICAgICBib2R5LmFwcGVuZENo
aWxkKGRldGFpbCk7CiAgICAgICAgICAgIGJvZHkuYXBwZW5kQ2hpbGQobWV0YSk7CiAgICAgICAgfSBl
bHNlIHsKICAgICAgICAgICAgY29uc3QgdXNlTSA9IGNsaXBVc2VzTUljb24oYyk7CiAgICAgICAgICAg
IGljby5jbGFzc05hbWUgPSB1c2VNID8gJ2ktaWNvIG1kJyA6ICdpLWljbyB0ZXh0JzsKICAgICAgICAg
ICAgaWNvLmlubmVySFRNTCA9IHVzZU0gPyAoU1ZHLm1kIHx8IFNWRy50ZXh0KSA6IFNWRy50ZXh0Owog
ICAgICAgICAgICAvKiBwbGFpbi1saXN0LXByZXYgKi8KICAgICAgICAgICAgLyogcHJldmlldy1lbGxp
cHNpcyAqLwogICAgICAgICAgICBsZXQgdHh0ICA9IGMucHJldmlldyB8fCBjLmRhdGEgfHwgJyc7CiAg
ICAgICAgICAgIHsgY29uc3QgX24gPSBOdW1iZXIoYy5jaGFyQ291bnQpIHx8IDA7IGlmIChfbiA+IHR4
dC5sZW5ndGggJiYgdHh0Lmxlbmd0aCkgdHh0ICs9ICcuLi4nOyB9CiAgICAgICAgICAgIGNvbnN0IHBy
ZXYgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgcHJldi5jbGFzc05h
bWUgID0gJ2ktcHJldicgKyAoaXNVcmwodHh0KSA/ICcgdXJsJyA6ICcnKTsKICAgICAgICAgICAgc2V0
SGxUZXh0KHByZXYsIHR4dCk7CgogICAgICAgICAgICBjb25zdCBtZXRhID0gZG9jdW1lbnQuY3JlYXRl
RWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIG1ldGEuY2xhc3NOYW1lID0gJ2ktbWV0YSc7CgogICAg
ICAgICAgICBjb25zdCBjaGFycyA9IE51bWJlcihjLmNoYXJDb3VudCkgfHwgMDsKICAgICAgICAgICAg
bGV0IHJpZ2h0SFRNTCA9IHNyY1RpdGxlSHRtbChjKTsKICAgICAgICAgICAgcmlnaHRIVE1MICs9IGA8
c3BhbiBjbGFzcz0iaS1jaGFycyI+PHNwYW4gY2xhc3M9Im4iPiR7Y2hhcnN9PC9zcGFuPiDlrZfnrKY8
L3NwYW4+YDsKCiAgICAgICAgICAgIG1ldGEuaW5uZXJIVE1MID0KICAgICAgICAgICAgICAgIGA8c3Bh
biBjbGFzcz0iaS10aW1lIj4ke2FnbyhjLnRpbWUpfTwvc3Bhbj5gICsKICAgICAgICAgICAgICAgIG1l
dGFDZW50ZXJIdG1sKHsKICAgICAgICAgICAgICAgICAgICBvbjogZmFsc2UsCiAgICAgICAgICAgICAg
ICAgICAgaHRtbDogYDxzdmcgdmlld0JveD0iMCAwIDE2IDE2IiB3aWR0aD0iMTAiIGhlaWdodD0iMTAi
IGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCIgc3Ryb2tl
LWxpbmVjYXA9InJvdW5kIj48cG9seWxpbmUgcG9pbnRzPSI0IDYgOCAxMCAxMiA2Ii8+PC9zdmc+YAog
ICAgICAgICAgICAgICAgfSkgKwogICAgICAgICAgICAgICAgYDxkaXYgY2xhc3M9ImktbWV0YS1yaWdo
dCB0ZXh0LW1ldGEiPiR7cmlnaHRIVE1MfTwvZGl2PmA7CgogICAgICAgICAgICBib2R5LmFwcGVuZENo
aWxkKHByZXYpOwogICAgICAgICAgICBib2R5LmFwcGVuZENoaWxkKG1ldGEpOwoKICAgICAgICAgICAg
Y29uc3QgZXhwQnRuID0gbWV0YS5xdWVyeVNlbGVjdG9yKCcuaS1leHBhbmQtYnRuJyk7CiAgICAgICAg
ICAgIGlmIChleHBCdG4pIHsKICAgICAgICAgICAgICAgIGV4cEJ0bi5vbmNsaWNrID0gZSA9PiB7CiAg
ICAgICAgICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgICAgICBj
b25zdCBleHBhbmRlZCA9IHByZXYuY2xhc3NMaXN0LnRvZ2dsZSgnZXhwYW5kZWQnKTsKICAgICAgICAg
ICAgICAgICAgICBleHBCdG4uaW5uZXJIVE1MID0gZXhwYW5kZWQKICAgICAgICAgICAgICAgICAgICAg
ICAgPyBgPHN2ZyB2aWV3Qm94PSIwIDAgMTYgMTYiIHdpZHRoPSIxMCIgaGVpZ2h0PSIxMCIgZmlsbD0i
bm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44IiBzdHJva2UtbGluZWNh
cD0icm91bmQiPjxwb2x5bGluZSBwb2ludHM9IjQgMTAgOCA2IDEyIDEwIi8+PC9zdmc+YAogICAgICAg
ICAgICAgICAgICAgICAgICA6IGA8c3ZnIHZpZXdCb3g9IjAgMCAxNiAxNiIgd2lkdGg9IjEwIiBoZWln
aHQ9IjEwIiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgi
IHN0cm9rZS1saW5lY2FwPSJyb3VuZCI+PHBvbHlsaW5lIHBvaW50cz0iNCA2IDggMTAgMTIgNiIvPjwv
c3ZnPmA7CiAgICAgICAgICAgICAgICB9OwogICAgICAgICAgICAgICAgY29uc3QgY2hlY2tPdmVyZmxv
dyA9ICgpID0+IHsKICAgICAgICAgICAgICAgICAgICBjb25zdCBwbGFpbkxlbiA9IFN0cmluZyhjLnBy
ZXZpZXcgfHwgYy5kYXRhIHx8ICcnKS5sZW5ndGg7CiAgICAgICAgICAgICAgICAgICAgY29uc3QgZnVs
bE4gPSBOdW1iZXIoYy5jaGFyQ291bnQpIHx8IDA7CiAgICAgICAgICAgICAgICAgICAgY29uc3QgdHJ1
bmMgPSBmdWxsTiA+IHBsYWluTGVuOwogICAgICAgICAgICAgICAgICAgIGlmIChwcmV2LnNjcm9sbEhl
aWdodCA+IHByZXYuY2xpZW50SGVpZ2h0ICsgMiB8fCB0cnVuYykKICAgICAgICAgICAgICAgICAgICAg
ICAgZXhwQnRuLmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAgICAgICAgICAgICAgICAgICAgZWxzZQogICAg
ICAgICAgICAgICAgICAgICAgICBleHBCdG4uY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICAg
ICAgICAgIH07CiAgICAgICAgICAgICAgICByZXF1ZXN0QW5pbWF0aW9uRnJhbWUoY2hlY2tPdmVyZmxv
dyk7CiAgICAgICAgICAgICAgICBzZXRUaW1lb3V0KGNoZWNrT3ZlcmZsb3csIDgwKTsKICAgICAgICAg
ICAgfQogICAgICAgIH0KCiAgICAgICAgY29uc3QgZmF2VCA9IFN0cmluZyhjLmZhdlRpdGxlIHx8ICcn
KS50cmltKCk7CiAgICAgICAgaWYgKGZhdlQpIHsKICAgICAgICAgICAgY29uc3QgZnQgPSBkb2N1bWVu
dC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgZnQuY2xhc3NOYW1lID0gJ2ktZmF2LXRp
dGxlJzsKICAgICAgICAgICAgc2V0SGxUZXh0KGZ0LCBmYXZUKTsKICAgICAgICAgICAgYm9keS5pbnNl
cnRCZWZvcmUoZnQsIGJvZHkuZmlyc3RDaGlsZCk7CiAgICAgICAgfQoKICAgICAgICBpZiAocGFzdGVk
KSB7CiAgICAgICAgICAgIGNvbnN0IGJhZGdlID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnc3Bhbicp
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
aWVudFksIGMpOwogICAgICAgIH07CgogICAgICAgIHJldHVybiBlbDsKICAgIH0KCiAgICBjb25zdCBw
YXRoVGlwRWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncGF0aC10aXAnKTsKICAgIGxldCBwYXRo
VGlwVGltZXIgPSAwOwogICAgbGV0IHBhdGhUaXBIaWRlVGltZXIgPSAwOwogICAgbGV0IHBhdGhUaXBU
b2tlbiA9IDA7CiAgICBsZXQgcGF0aFRpcEFuY2hvckJ0biA9IG51bGw7CgogICAgZnVuY3Rpb24gaGlk
ZVBhdGhUaXAoKSB7CiAgICAgICAgY2xlYXJUaW1lb3V0KHBhdGhUaXBUaW1lcik7CiAgICAgICAgY2xl
YXJUaW1lb3V0KHBhdGhUaXBIaWRlVGltZXIpOwogICAgICAgIHBhdGhUaXBUb2tlbisrOwogICAgICAg
IGlmIChwYXRoVGlwQW5jaG9yQnRuKSB7CiAgICAgICAgICAgIHBhdGhUaXBBbmNob3JCdG4uY2xhc3NM
aXN0LnJlbW92ZSgnb24nKTsKICAgICAgICAgICAgcGF0aFRpcEFuY2hvckJ0biA9IG51bGw7CiAgICAg
ICAgfQogICAgICAgIGlmIChwYXRoVGlwRWwpIHsKICAgICAgICAgICAgcGF0aFRpcEVsLmNsYXNzTGlz
dC5yZW1vdmUoJ29uJyk7CiAgICAgICAgICAgIHBhdGhUaXBFbC5zZXRBdHRyaWJ1dGUoJ2FyaWEtaGlk
ZGVuJywgJ3RydWUnKTsKICAgICAgICB9CiAgICB9CiAgICBmdW5jdGlvbiBwbGFjZVBhdGhUaXAoYW5j
aG9yRWwpIHsKICAgICAgICBpZiAoIXBhdGhUaXBFbCB8fCAhYW5jaG9yRWwpIHJldHVybjsKICAgICAg
ICBjb25zdCB0aXAgPSBwYXRoVGlwRWw7CiAgICAgICAgY29uc3QgYXIgPSBhbmNob3JFbC5nZXRCb3Vu
ZGluZ0NsaWVudFJlY3QoKTsKICAgICAgICBjb25zdCBwYWQgPSA4OwogICAgICAgIHRpcC5zdHlsZS5s
ZWZ0ID0gJzBweCc7CiAgICAgICAgdGlwLnN0eWxlLnRvcCA9ICcwcHgnOwogICAgICAgIHRpcC5jbGFz
c0xpc3QuYWRkKCdvbicpOwogICAgICAgIGNvbnN0IHR3ID0gdGlwLm9mZnNldFdpZHRoOwogICAgICAg
IGNvbnN0IHRoID0gdGlwLm9mZnNldEhlaWdodDsKICAgICAgICBsZXQgbGVmdCA9IGFyLmxlZnQ7CiAg
ICAgICAgbGV0IHRvcCA9IGFyLmJvdHRvbSArIDY7CiAgICAgICAgaWYgKGxlZnQgKyB0dyA+IHdpbmRv
dy5pbm5lcldpZHRoIC0gcGFkKQogICAgICAgICAgICBsZWZ0ID0gTWF0aC5tYXgocGFkLCB3aW5kb3cu
aW5uZXJXaWR0aCAtIHR3IC0gcGFkKTsKICAgICAgICBpZiAobGVmdCA8IHBhZCkgbGVmdCA9IHBhZDsK
ICAgICAgICBpZiAodG9wICsgdGggPiB3aW5kb3cuaW5uZXJIZWlnaHQgLSBwYWQpCiAgICAgICAgICAg
IHRvcCA9IE1hdGgubWF4KHBhZCwgYXIudG9wIC0gdGggLSA2KTsKICAgICAgICB0aXAuc3R5bGUubGVm
dCA9IGxlZnQgKyAncHgnOwogICAgICAgIHRpcC5zdHlsZS50b3AgPSB0b3AgKyAncHgnOwogICAgfQog
ICAgICAgIGZ1bmN0aW9uIGNoZWNrRmlsZVBhdGhzKHBhdGhzKSB7CiAgICAgICAgY29uc3QgbGlzdCA9
IChwYXRocyB8fCBbXSkubWFwKHAgPT4gewogICAgICAgICAgICBsZXQgcGF0aCA9IFN0cmluZyhwIHx8
ICcnKS50cmltKCk7CiAgICAgICAgICAgIGlmICgocGF0aC5zdGFydHNXaXRoKCciJykgJiYgcGF0aC5l
bmRzV2l0aCgnIicpKSB8fCAocGF0aC5zdGFydHNXaXRoKCInIikgJiYgcGF0aC5lbmRzV2l0aCgiJyIp
KSkKICAgICAgICAgICAgICAgIHBhdGggPSBwYXRoLnNsaWNlKDEsIC0xKS50cmltKCk7CiAgICAgICAg
ICAgIHJldHVybiBwYXRoOwogICAgICAgIH0pOwogICAgICAgIC8vIE9uZSBob3N0IHJvdW5kLXRyaXAg
Zm9yIHRoZSB3aG9sZSBsaXN0IOKAlCBOw5cgcGF0aEV4aXN0cyBmcmVlemVzIGZpbGUgdGFiCiAgICAg
ICAgdHJ5IHsKICAgICAgICAgICAgY29uc3QgcmF3ID0gYWhrUmV0KCdjaGVja1BhdGhzJywgbGlzdC5q
b2luKCdcbicpKTsKICAgICAgICAgICAgaWYgKHJhdykgewogICAgICAgICAgICAgICAgY29uc3QgcGFy
c2VkID0gdHlwZW9mIHJhdyA9PT0gJ3N0cmluZycgPyBKU09OLnBhcnNlKHJhdykgOiByYXc7CiAgICAg
ICAgICAgICAgICBpZiAoQXJyYXkuaXNBcnJheShwYXJzZWQpICYmIHBhcnNlZC5sZW5ndGgpIHsKICAg
ICAgICAgICAgICAgICAgICByZXR1cm4gbGlzdC5tYXAoKHBhdGgsIGkpID0+IHsKICAgICAgICAgICAg
ICAgICAgICAgICAgY29uc3Qgcm93ID0gcGFyc2VkW2ldIHx8IHt9OwogICAgICAgICAgICAgICAgICAg
ICAgICByZXR1cm4gewogICAgICAgICAgICAgICAgICAgICAgICAgICAgcGF0aDogcGF0aCB8fCBTdHJp
bmcocm93LnBhdGggfHwgJycpLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgZXhpc3RzOiByb3cu
ZXhpc3RzID09PSB0cnVlIHx8IHJvdy5leGlzdHMgPT09IDEgfHwgcm93LmV4aXN0cyA9PT0gJzEnLAog
ICAgICAgICAgICAgICAgICAgICAgICAgICAgaXNEaXI6ICEhKHJvdy5pc0RpciA9PT0gdHJ1ZSB8fCBy
b3cuaXNEaXIgPT09IDEgfHwgcm93LmlzRGlyID09PSAnMScpCiAgICAgICAgICAgICAgICAgICAgICAg
IH07CiAgICAgICAgICAgICAgICAgICAgfSk7CiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgIH0K
ICAgICAgICB9IGNhdGNoIHt9CiAgICAgICAgcmV0dXJuIGxpc3QubWFwKHBhdGggPT4gewogICAgICAg
ICAgICBpZiAoIXBhdGgpIHJldHVybiB7IHBhdGgsIGV4aXN0czogZmFsc2UsIGlzRGlyOiBmYWxzZSB9
OwogICAgICAgICAgICBsZXQgZXhpc3RzID0gZmFsc2U7CiAgICAgICAgICAgIHRyeSB7CiAgICAgICAg
ICAgICAgICBjb25zdCBmbGFnID0gU3RyaW5nKGFoa1JldCgncGF0aEV4aXN0cycsIHBhdGgpID8/ICcn
KS50cmltKCkudG9Mb3dlckNhc2UoKTsKICAgICAgICAgICAgICAgIGV4aXN0cyA9IChmbGFnID09PSAn
MScgfHwgZmxhZyA9PT0gJ3RydWUnKTsKICAgICAgICAgICAgfSBjYXRjaCB7fQogICAgICAgICAgICBy
ZXR1cm4geyBwYXRoLCBleGlzdHMsIGlzRGlyOiBmYWxzZSB9OwogICAgICAgIH0pOwogICAgfQogICAg
bGV0IGdvbmVDaGVja1RpbWVyID0gMDsKICAgIGZ1bmN0aW9uIHNjaGVkdWxlRmlsZUdvbmVDaGVjaygp
IHsKICAgICAgICBpZiAoZ29uZUNoZWNrVGltZXIpIHJldHVybjsKICAgICAgICBnb25lQ2hlY2tUaW1l
ciA9IHNldFRpbWVvdXQoKCkgPT4gewogICAgICAgICAgICBnb25lQ2hlY2tUaW1lciA9IDA7CiAgICAg
ICAgICAgIGNvbnN0IG5vZGVzID0gWy4uLmxpc3RFbC5xdWVyeVNlbGVjdG9yQWxsKCcuaXRtJyldLmZp
bHRlcihuID0+IG4uX2ZpbGVQYXRocyAmJiBuLl9maWxlUGF0aHMubGVuZ3RoKTsKICAgICAgICAgICAg
aWYgKCFub2Rlcy5sZW5ndGgpIHJldHVybjsKICAgICAgICAgICAgY29uc3QgdW5pcXVlID0gW107CiAg
ICAgICAgICAgIGNvbnN0IHNlZW4gPSBuZXcgU2V0KCk7CiAgICAgICAgICAgIG5vZGVzLmZvckVhY2go
biA9PiB7CiAgICAgICAgICAgICAgICBuLl9maWxlUGF0aHMuZm9yRWFjaChwID0+IHsKICAgICAgICAg
ICAgICAgICAgICBjb25zdCBwYXRoID0gU3RyaW5nKHAgfHwgJycpOwogICAgICAgICAgICAgICAgICAg
IGlmICghcGF0aCB8fCBzZWVuLmhhcyhwYXRoKSkgcmV0dXJuOwogICAgICAgICAgICAgICAgICAgIHNl
ZW4uYWRkKHBhdGgpOwogICAgICAgICAgICAgICAgICAgIHVuaXF1ZS5wdXNoKHBhdGgpOwogICAgICAg
ICAgICAgICAgfSk7CiAgICAgICAgICAgIH0pOwogICAgICAgICAgICBjb25zdCByb3dzID0gY2hlY2tG
aWxlUGF0aHModW5pcXVlKTsKICAgICAgICAgICAgY29uc3QgYnlQYXRoID0gbmV3IE1hcCgpOwogICAg
ICAgICAgICByb3dzLmZvckVhY2gociA9PiBieVBhdGguc2V0KFN0cmluZyhyLnBhdGggfHwgJycpLCBy
KSk7CiAgICAgICAgICAgIG5vZGVzLmZvckVhY2gobiA9PiB7CiAgICAgICAgICAgICAgICBjb25zdCBw
YXRoUm93cyA9IG4uX2ZpbGVQYXRocy5tYXAocCA9PiB7CiAgICAgICAgICAgICAgICAgICAgY29uc3Qg
aGl0ID0gYnlQYXRoLmdldChTdHJpbmcocCB8fCAnJykpOwogICAgICAgICAgICAgICAgICAgIHJldHVy
biBoaXQgfHwgeyBwYXRoOiBwLCBleGlzdHM6IHRydWUsIGlzRGlyOiBmYWxzZSB9OwogICAgICAgICAg
ICAgICAgfSk7CiAgICAgICAgICAgICAgICBuLl9wYXRoUm93cyA9IHBhdGhSb3dzOwogICAgICAgICAg
ICAgICAgY29uc3QgYWxsR29uZSA9IHBhdGhSb3dzLmxlbmd0aCA+IDAgJiYgcGF0aFJvd3MuZXZlcnko
ciA9PiByLmV4aXN0cyA9PT0gZmFsc2UpOwogICAgICAgICAgICAgICAgbi5jbGFzc0xpc3QudG9nZ2xl
KCdnb25lJywgYWxsR29uZSk7CiAgICAgICAgICAgIH0pOwogICAgICAgIH0sIDApOwogICAgfQogICAg
ZnVuY3Rpb24gZmlsbEZpbGVEZXRhaWxQYW5lbChjb250YWluZXIsIHJvd3MpIHsKICAgICAgICBjb250
YWluZXIuaW5uZXJIVE1MID0gJyc7CiAgICAgICAgaWYgKCFyb3dzLmxlbmd0aCkgewogICAgICAgICAg
ICBjb25zdCBlbXB0eSA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgICAgICAgICBl
bXB0eS5jbGFzc05hbWUgPSAnZmQtcGF0aCc7CiAgICAgICAgICAgIGVtcHR5LnRleHRDb250ZW50ID0g
J+aXoOi3r+W+hCc7CiAgICAgICAgICAgIGNvbnRhaW5lci5hcHBlbmRDaGlsZChlbXB0eSk7CiAgICAg
ICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgcm93cy5mb3JFYWNoKHIgPT4gewogICAgICAg
ICAgICBjb25zdCBwYXRoID0gU3RyaW5nKHIucGF0aCB8fCAnJyk7CiAgICAgICAgICAgIGNvbnN0IG1p
c3NpbmcgPSByLmV4aXN0cyA9PT0gZmFsc2U7CiAgICAgICAgICAgIGNvbnN0IGJsb2NrID0gZG9jdW1l
bnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIGJsb2NrLmNsYXNzTmFtZSA9ICdmZC1i
bG9jayc7CgogICAgICAgICAgICBjb25zdCBwYXRoRWwgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdk
aXYnKTsKICAgICAgICAgICAgcGF0aEVsLmNsYXNzTmFtZSA9ICdmZC1wYXRoJyArIChtaXNzaW5nID8g
JyBkZWFkJyA6ICcgbGl2ZScpOwogICAgICAgICAgICBwYXRoRWwudGV4dENvbnRlbnQgPSBwYXRoIHx8
ICco56m66Lev5b6EKSc7CiAgICAgICAgICAgIGlmICghbWlzc2luZykgewogICAgICAgICAgICAgICAg
cGF0aEVsLm9uY2xpY2sgPSBlID0+IHsKICAgICAgICAgICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0
KCk7CiAgICAgICAgICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAg
ICAgICBhaGsoJ29wZW5QYXRoJywgcGF0aCk7CiAgICAgICAgICAgICAgICB9OwogICAgICAgICAgICB9
CiAgICAgICAgICAgIGJsb2NrLmFwcGVuZENoaWxkKHBhdGhFbCk7CgogICAgICAgICAgICBjb25zdCBh
Y3Rpb25zID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIGFjdGlvbnMu
Y2xhc3NOYW1lID0gJ2ZkLWFjdGlvbnMnOwoKICAgICAgICAgICAgY29uc3QgY29weUJ0biA9IGRvY3Vt
ZW50LmNyZWF0ZUVsZW1lbnQoJ2J1dHRvbicpOwogICAgICAgICAgICBjb3B5QnRuLnR5cGUgPSAnYnV0
dG9uJzsKICAgICAgICAgICAgY29weUJ0bi5jbGFzc05hbWUgPSAnZmQtYnRuJzsKICAgICAgICAgICAg
Y29weUJ0bi5pbm5lckhUTUwgPSAnPHNwYW4gY2xhc3M9ImZkLWljbyI+8J+Ulzwvc3Bhbj48c3BhbiBj
bGFzcz0iZmQtdHh0Ij7lpI3liLbot6/lvoQ8L3NwYW4+JzsKICAgICAgICAgICAgY29weUJ0bi5vbmNs
aWNrID0gZSA9PiB7CiAgICAgICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAg
ICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAgYWhrKCdjb3B5UGF0aCcsIHBh
dGgpOwogICAgICAgICAgICAgICAgY29weUJ0bi5xdWVyeVNlbGVjdG9yKCcuZmQtdHh0JykudGV4dENv
bnRlbnQgPSAn5bey5aSN5Yi2JzsKICAgICAgICAgICAgICAgIGNvcHlCdG4uY2xhc3NMaXN0LmFkZCgn
b2snKTsKICAgICAgICAgICAgICAgIHNldFRpbWVvdXQoKCkgPT4gewogICAgICAgICAgICAgICAgICAg
IGNvcHlCdG4ucXVlcnlTZWxlY3RvcignLmZkLXR4dCcpLnRleHRDb250ZW50ID0gJ+WkjeWItui3r+W+
hCc7CiAgICAgICAgICAgICAgICAgICAgY29weUJ0bi5jbGFzc0xpc3QucmVtb3ZlKCdvaycpOwogICAg
ICAgICAgICAgICAgfSwgMTIwMCk7CiAgICAgICAgICAgIH07CiAgICAgICAgICAgIGFjdGlvbnMuYXBw
ZW5kQ2hpbGQoY29weUJ0bik7CgogICAgICAgICAgICBjb25zdCBmb2xkZXJCdG4gPSBkb2N1bWVudC5j
cmVhdGVFbGVtZW50KCdidXR0b24nKTsKICAgICAgICAgICAgZm9sZGVyQnRuLnR5cGUgPSAnYnV0dG9u
JzsKICAgICAgICAgICAgZm9sZGVyQnRuLmNsYXNzTmFtZSA9ICdmZC1idG4nOwogICAgICAgICAgICBm
b2xkZXJCdG4uaW5uZXJIVE1MID0gJzxzcGFuIGNsYXNzPSJmZC1pY28iPvCfk4I8L3NwYW4+PHNwYW4g
Y2xhc3M9ImZkLXR4dCI+5omT5byA5omA5Zyo5paH5Lu25aS5PC9zcGFuPic7CiAgICAgICAgICAgIGZv
bGRlckJ0bi5vbmNsaWNrID0gZSA9PiB7CiAgICAgICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7
CiAgICAgICAgICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAgYWhrKCdv
cGVuRm9sZGVyJywgcGF0aCk7CiAgICAgICAgICAgIH07CiAgICAgICAgICAgIGFjdGlvbnMuYXBwZW5k
Q2hpbGQoZm9sZGVyQnRuKTsKCiAgICAgICAgICAgIGJsb2NrLmFwcGVuZENoaWxkKGFjdGlvbnMpOwog
ICAgICAgICAgICBjb250YWluZXIuYXBwZW5kQ2hpbGQoYmxvY2spOwogICAgICAgIH0pOwogICAgfQoK
ICAgIGNvbnN0IGN0eEVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2N0eCcpOwogICAgZnVuY3Rp
b24gc2hvd0N0eCh4LCB5LCBjKSB7CiAgICAgICAgY3R4Q2xpcCA9IGM7CiAgICAgICAgc2VsZWN0ZWRJ
ZCA9IGMuaWQ7CiAgICAgICAgcmFuZ2VBbmNob3JJZCA9IGMuaWQ7CiAgICAgICAgcmFuZ2VBbmNob3JD
bGlja2VkID0gdHJ1ZTsKICAgICAgICBjb25zdCBjbGVhckJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRC
eUlkKCdjLWNsZWFyLXBhc3RlZCcpOwogICAgICAgIGlmIChjbGVhckJ0bikgY2xlYXJCdG4uc3R5bGUu
ZGlzcGxheSA9IGlzUGFzdGVkKGMpID8gJycgOiAnbm9uZSc7CgogICAgICAgIGNvbnN0IHBpbkJ0biA9
IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjLXBpbicpOwogICAgICAgIGlmIChwaW5CdG4pIHsKICAg
ICAgICAgICAgY29uc3Qgb24gPSBpc1Bpbm5lZChjKTsKICAgICAgICAgICAgcGluQnRuLmlubmVySFRN
TCA9IG9uCiAgICAgICAgICAgICAgICA/ICc8c3BhbiBjbGFzcz0iYy1pY28iPuKYhTwvc3Bhbj7lj5bm
tojmlLbol48nCiAgICAgICAgICAgICAgICA6ICc8c3BhbiBjbGFzcz0iYy1pY28iPuKYhTwvc3Bhbj7m
lLbol48nOwogICAgICAgIH0KICAgICAgICBjb25zdCB0aXRsZUJ0biA9IGRvY3VtZW50LmdldEVsZW1l
bnRCeUlkKCdjLXRpdGxlJyk7CiAgICAgICAgaWYgKHRpdGxlQnRuKSB7CiAgICAgICAgICAgIGNvbnN0
IHNob3dUaXRsZSA9IGlzUGlubmVkKGMpIHx8IGN1clRhYiA9PT0gJ3Bpbm5lZCc7CiAgICAgICAgICAg
IHRpdGxlQnRuLnN0eWxlLmRpc3BsYXkgPSBzaG93VGl0bGUgPyAnJyA6ICdub25lJzsKICAgICAgICAg
ICAgaWYgKHNob3dUaXRsZSkKICAgICAgICAgICAgICAgIHRpdGxlQnRuLmlubmVySFRNTCA9IChTdHJp
bmcoYy5mYXZUaXRsZSB8fCAnJykudHJpbSgpID8gJzxzcGFuIGNsYXNzPSJjLWljbyI+4pyOPC9zcGFu
Pue8lui+keagh+mimCcgOiAnPHNwYW4gY2xhc3M9ImMtaWNvIj7inI48L3NwYW4+6K6+572u5qCH6aKY
Jyk7CiAgICAgICAgfQogICAgICAgIGNvbnN0IG1lcmdlQnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ2MtbWVyZ2UnKTsKICAgICAgICBjb25zdCB1bm1lcmdlQnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVu
dEJ5SWQoJ2MtdW5tZXJnZScpOwogICAgICAgIGNvbnN0IG9uUGlubmVkID0gY3VyVGFiID09PSAncGlu
bmVkJzsKICAgICAgICBpZiAobWVyZ2VCdG4pCiAgICAgICAgICAgIG1lcmdlQnRuLnN0eWxlLmRpc3Bs
YXkgPSAob25QaW5uZWQgJiYgbXVsdGlJZHMubGVuZ3RoID49IDIpID8gJycgOiAnbm9uZSc7CiAgICAg
ICAgaWYgKHVubWVyZ2VCdG4pCiAgICAgICAgICAgIHVubWVyZ2VCdG4uc3R5bGUuZGlzcGxheSA9IChv
blBpbm5lZCAmJiBmYXZHcm91cE9mKGMpKSA/ICcnIDogJ25vbmUnOwogICAgICAgIGN0eEVsLmNsYXNz
TGlzdC5hZGQoJ29uJyk7CiAgICAgICAgY3R4RWwuc3R5bGUubGVmdCA9IHggKyAncHgnOwogICAgICAg
IGN0eEVsLnN0eWxlLnRvcCAgPSB5ICsgJ3B4JzsKICAgICAgICByZXF1ZXN0QW5pbWF0aW9uRnJhbWUo
KCkgPT4gewogICAgICAgICAgICBjb25zdCByID0gY3R4RWwuZ2V0Qm91bmRpbmdDbGllbnRSZWN0KCk7
CiAgICAgICAgICAgIGlmIChyLnJpZ2h0ICA+IGlubmVyV2lkdGgpICBjdHhFbC5zdHlsZS5sZWZ0ID0g
KHggLSByLndpZHRoKSAgKyAncHgnOwogICAgICAgICAgICBpZiAoci5ib3R0b20gPiBpbm5lckhlaWdo
dCkgY3R4RWwuc3R5bGUudG9wICA9ICh5IC0gci5oZWlnaHQpICsgJ3B4JzsKICAgICAgICB9KTsKICAg
IH0KICAgIGZ1bmN0aW9uIGhpZGVDdHgoKSB7IGN0eEVsLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7IGN0
eENsaXAgPSBudWxsOyB9CiAgICB3aW5kb3cuX19oaWRlQ3R4ID0gaGlkZUN0eDsKCiAgICBmdW5jdGlv
biBkaXNtaXNzQ3R4VW5sZXNzSW5zaWRlKGUpIHsKICAgICAgICBpZiAoIWN0eEVsLmNsYXNzTGlzdC5j
b250YWlucygnb24nKSkgcmV0dXJuOwogICAgICAgIGlmIChlLnRhcmdldC5jbG9zZXN0KCcjY3R4Jykp
IHJldHVybjsKICAgICAgICBoaWRlQ3R4KCk7CiAgICB9CiAgICBkb2N1bWVudC5hZGRFdmVudExpc3Rl
bmVyKCdtb3VzZWRvd24nLCBkaXNtaXNzQ3R4VW5sZXNzSW5zaWRlLCB0cnVlKTsKICAgIGRvY3VtZW50
LmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZGlzbWlzc0N0eFVubGVzc0luc2lkZSwgdHJ1ZSk7CiAg
ICBsaXN0RWwuYWRkRXZlbnRMaXN0ZW5lcignc2Nyb2xsJywgaGlkZUN0eCwgeyBwYXNzaXZlOiB0cnVl
IH0pOwogICAgZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5lcigna2V5ZG93bicsIGUgPT4gewogICAgICAg
IC8vIEVzYzogYWx3YXlzIGNsb3NlIHBhbmVsIChzZWFyY2ggb3Igbm90KTsgcGluIGtlZXBzIHBhbmVs
CiAgICAgICAgaWYgKGUua2V5ID09PSAnRXNjYXBlJykgewogICAgICAgICAgICBlLnByZXZlbnREZWZh
dWx0KCk7CiAgICAgICAgICAgIGhpZGVDdHgoKTsKICAgICAgICAgICAgY29uc3QgdGQgPSBkb2N1bWVu
dC5nZXRFbGVtZW50QnlJZCgndGl0bGUtZGxnJyk7CiAgICAgICAgICAgIGlmICh0ZCAmJiB0ZC5jbGFz
c0xpc3QuY29udGFpbnMoJ29uJykpIHsKICAgICAgICAgICAgICAgIHRyeSB7IGNsb3NlVGl0bGVEbGco
KTsgfSBjYXRjaCB7IHRkLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7IH0KICAgICAgICAgICAgICAgIHJl
dHVybjsKICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAoY2xyRGxnLmNsYXNzTGlzdC5jb250YWlu
cygnb24nKSkgewogICAgICAgICAgICAgICAgY2xvc2VDbGVhckRsZygpOwogICAgICAgICAgICAgICAg
cmV0dXJuOwogICAgICAgICAgICB9CiAgICAgICAgICAgIGlmICghcGlubmVkVUkpIGFoaygnaGlkZScp
OwogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIC8vIFdoaWxlIHR5cGluZyBpbiBz
ZWFyY2g6IEN0cmwrSS9LIGFuZCBhcnJvd3MgbW92ZSBsaXN0LCBkb24ndCBsZWF2ZSB0aGUgYm94CiAg
ICAgICAgaWYgKGRvY3VtZW50LmFjdGl2ZUVsZW1lbnQ/LmlkID09PSAnc2VhcmNoJykgewogICAgICAg
ICAgICBpZiAoKGUuY3RybEtleSB8fCBlLm1ldGFLZXkpICYmIChlLmtleSA9PT0gJ2knIHx8IGUua2V5
ID09PSAnSScpKSB7CiAgICAgICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3Bh
Z2F0aW9uKCk7CiAgICAgICAgICAgICAgICB3aW5kb3cuX19uYXYgJiYgd2luZG93Ll9fbmF2KCd1cCcp
OwogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICB9CiAgICAgICAgICAgIGlmICgoZS5j
dHJsS2V5IHx8IGUubWV0YUtleSkgJiYgKGUua2V5ID09PSAnaycgfHwgZS5rZXkgPT09ICdLJykpIHsK
ICAgICAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAg
ICAgICAgICAgICAgIHdpbmRvdy5fX25hdiAmJiB3aW5kb3cuX19uYXYoJ2Rvd24nKTsKICAgICAgICAg
ICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAoZS5rZXkgPT09ICdBcnJv
d0Rvd24nKSB7CiAgICAgICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0
aW9uKCk7CiAgICAgICAgICAgICAgICB3aW5kb3cuX19uYXYgJiYgd2luZG93Ll9fbmF2KCdkb3duJyk7
CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgaWYgKGUua2V5
ID09PSAnQXJyb3dVcCcpIHsKICAgICAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsgZS5zdG9w
UHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgICAgIHdpbmRvdy5fX25hdiAmJiB3aW5kb3cuX19uYXYo
J3VwJyk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgcmV0
dXJuOwogICAgICAgIH0KICAgICAgICBjb25zdCB2aXMgPSAodHlwZW9mIG5hdkxpc3QgPT09ICdmdW5j
dGlvbicgPyBuYXZMaXN0KCkgOiB2aXNpYmxlTGlzdCgpKTsKICAgICAgICBpZiAoIXZpcy5sZW5ndGgp
IHJldHVybjsKICAgICAgICBsZXQgaWR4ID0gc2VsZWN0ZWRJbmRleCgpOwogICAgICAgIGlmIChpZHgg
PCAwKSBpZHggPSAwOwogICAgICAgIGlmICAgICAgKGUua2V5ID09PSAnQXJyb3dEb3duJykgeyBlLnBy
ZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0aW9uKCk7IHNlbGVjdEJ5SW5kZXgoaWR4ICsgMSk7
IH0KICAgICAgICBlbHNlIGlmIChlLmtleSA9PT0gJ0Fycm93VXAnKSAgIHsgZS5wcmV2ZW50RGVmYXVs
dCgpOyBlLnN0b3BQcm9wYWdhdGlvbigpOyBzZWxlY3RCeUluZGV4KGlkeCAtIDEpOyB9CiAgICAgICAg
ZWxzZSBpZiAoZS5rZXkgPT09ICdFbnRlcicpIHsKICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgp
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
MSk7CiAgICAgICAgZWxzZSBpZiAoZGlyID09PSAnZW50ZXInKSB7CiAgICAgICAgICAgIF9fcHJlcFBh
c3RlKCk7CiAgICAgICAgICAgIGlmIChtdWx0aUlkcy5sZW5ndGggPiAxKSB7CiAgICAgICAgICAgICAg
ICBjb25zdCBpZHMgPSBtdWx0aUlkcy5zbGljZSgpOwogICAgICAgICAgICAgICAgY2xlYXJNdWx0aSgp
OwogICAgICAgICAgICAgICAgbWFya1Bhc3RlZExvY2FsKGlkcyk7CiAgICAgICAgICAgICAgICBhaGso
J3Bhc3RlTWFueScsIGlkcy5qb2luKCcsJykpOwogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAg
ICAgICB9CiAgICAgICAgICAgIGlmIChtdWx0aUlkcy5sZW5ndGggPT09IDEpIHsKICAgICAgICAgICAg
ICAgIGNvbnN0IGlkID0gbXVsdGlJZHNbMF07CiAgICAgICAgICAgICAgICBjbGVhck11bHRpKCk7CiAg
ICAgICAgICAgICAgICBtYXJrUGFzdGVkTG9jYWwoaWQpOwogICAgICAgICAgICAgICAgYWhrKCdwYXN0
ZScsIFN0cmluZyhpZCkpOwogICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICB9CiAgICAg
ICAgICAgIGNvbnN0IGMgPSB2aXNbc2VsZWN0ZWRJbmRleCgpXTsKICAgICAgICAgICAgaWYgKGMpIHsK
ICAgICAgICAgICAgICAgIG1hcmtQYXN0ZWRMb2NhbChjLmlkKTsKICAgICAgICAgICAgICAgIGFoaygn
cGFzdGUnLCBTdHJpbmcoYy5pZCkpOwogICAgICAgICAgICB9CiAgICAgICAgfQogICAgfTsKCiAgICAv
LyBBSEsgRW50ZXIgaG90a2V5IGxhbmRzIGhlcmUgKFdlYlZpZXcgbWF5IG5vdCByZWNlaXZlIHRoZSBr
ZXkgd2hpbGUgdW5waW5uZWQpCiAgICB3aW5kb3cuX19lZGl0VGl0bGUgPSAoKSA9PiB7CiAgICAgICAg
bGV0IGMgPSBudWxsOwogICAgICAgIGlmIChzZWxlY3RlZElkKQogICAgICAgICAgICBjID0gYWxsQ2xp
cHMuZmluZCh4ID0+ICt4LmlkID09PSArc2VsZWN0ZWRJZCkgfHwgbnVsbDsKICAgICAgICBpZiAoIWMg
JiYgY3R4Q2xpcCkKICAgICAgICAgICAgYyA9IGN0eENsaXA7CiAgICAgICAgaWYgKCFjKSB7CiAgICAg
ICAgICAgIGNvbnN0IHZpcyA9IHZpc2libGVMaXN0KCk7CiAgICAgICAgICAgIGlmICh2aXMubGVuZ3Ro
KSBjID0gdmlzWzBdOwogICAgICAgIH0KICAgICAgICBpZiAoIWMpIHJldHVybjsKICAgICAgICBvcGVu
VGl0bGVEbGcoYyk7CiAgICB9OwoKICAgIHdpbmRvdy5fX29uRW50ZXIgPSAoKSA9PiB7CiAgICAgICAg
Y29uc3QgdGQgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGl0bGUtZGxnJyk7CiAgICAgICAgaWYg
KHRkICYmIHRkLmNsYXNzTGlzdC5jb250YWlucygnb24nKSkgewogICAgICAgICAgICBkb2N1bWVudC5n
ZXRFbGVtZW50QnlJZCgndGl0bGUtb2snKT8uY2xpY2soKTsKICAgICAgICAgICAgcmV0dXJuOwogICAg
ICAgIH0KICAgICAgICBpZiAoZG9jdW1lbnQuYWN0aXZlRWxlbWVudD8uaWQgPT09ICd0aXRsZS1pbnB1
dCcpIHsKICAgICAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RpdGxlLW9rJyk/LmNsaWNr
KCk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgLy8gVHlwaW5nIGluIHNlYXJj
aDogRW50ZXIgc2hvdWxkIHBhc3RlIHNlbGVjdGVkIGl0ZW0KICAgICAgICBpZiAoZG9jdW1lbnQuYWN0
aXZlRWxlbWVudD8uaWQgPT09ICdzZWFyY2gnKSB7CiAgICAgICAgICAgIHdpbmRvdy5fX25hdiAmJiB3
aW5kb3cuX19uYXYoJ2VudGVyJyk7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAg
d2luZG93Ll9fbmF2ICYmIHdpbmRvdy5fX25hdignZW50ZXInKTsKICAgIH07CgogICAgd2luZG93Ll9f
Y3ljbGVUYWIgPSBkaXIgPT4gewogICAgICAgIGNvbnN0IGkgPSBNYXRoLm1heCgwLCBUQUJfT1JERVIu
aW5kZXhPZihjdXJUYWIpKTsKICAgICAgICBjb25zdCBuZXh0ID0gVEFCX09SREVSWyhpICsgKGRpciB8
IDApICsgVEFCX09SREVSLmxlbmd0aCAqIDEwKSAlIFRBQl9PUkRFUi5sZW5ndGhdOwogICAgICAgIHNl
dFRhYihuZXh0KTsKICAgIH07CiAgICB3aW5kb3cuX19vblBhbmVsU2hvdyA9IChrZWVwU2VhcmNoKSA9
PiB7CiAgICAgICAgLy8gRG8gTk9UIGZvY3VzIFdlYlZpZXcg4oCUIGtlZXAgZWRpdG9yIGNhcmV0L2Zv
Y3VzIChBSEsgaGFuZGxlcyBrZXlzIHZpYSAjSG90SWYpCiAgICAgICAgLy8gV2luK1Y6IGNvbGxhcHNl
IHNlYXJjaC4gPz8gc2VhcmNoOiBrZWVwL29wZW4gc2VhcmNoIGJveC4KICAgICAgICBrZWVwU2VhcmNo
ID0gISFrZWVwU2VhcmNoOwogICAgICAgIHRyeSB7IGhpZGVDdHgoKTsgfSBjYXRjaCB7fQogICAgICAg
IHRyeSB7IGNsb3NlVGl0bGVEbGcoKTsgfSBjYXRjaCB7fQogICAgICAgIHRyeSB7CiAgICAgICAgICAg
IGNvbnN0IHdyYXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoLXdyYXAnKTsKICAgICAg
ICAgICAgY29uc3Qgc3JjaCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gnKTsKICAgICAg
ICAgICAgY29uc3Qgc2NsciA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gtY2xyJyk7CiAg
ICAgICAgICAgIGlmICgha2VlcFNlYXJjaCkgewogICAgICAgICAgICAgICAgaWYgKHdyYXApIHdyYXAu
Y2xhc3NMaXN0LnJlbW92ZSgnb3BlbicpOwogICAgICAgICAgICAgICAgaWYgKHNyY2gpIHsKICAgICAg
ICAgICAgICAgICAgICBzcmNoLnZhbHVlID0gJyc7CiAgICAgICAgICAgICAgICAgICAgc3JjaC5jbGFz
c0xpc3QucmVtb3ZlKCdoYXMtdmFsJyk7CiAgICAgICAgICAgICAgICAgICAgdHJ5IHsgc3JjaC5ibHVy
KCk7IH0gY2F0Y2gge30KICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgIGlmIChzY2xyKSBz
Y2xyLnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgICAgICAgICAgICAgICBxdWVyeSA9ICcnOwogICAg
ICAgICAgICAgICAgd2luZG93Ll9faG9zdEZpbHRlcmVkID0gZmFsc2U7CiAgICAgICAgICAgICAgICAv
LyBXaW4rVu+8mueri+WIu+eUqOacqui/h+a7pOe8k+WtmOmTuuWIl+ihqO+8jOmBv+WFjeWFiOmXqui/
h+a7pOe7k+aenC/nqbrlo7Plho3nrYkgU2V0VmlldwogICAgICAgICAgICAgICAgdHJ5IHsKICAgICAg
ICAgICAgICAgICAgICBjb25zdCBoaXQgPSB2aWV3TWVtLmdldCh2aWV3TWVtS2V5KCdhbGwnLCAnJywg
ZmFsc2UpKTsKICAgICAgICAgICAgICAgICAgICBpZiAoaGl0ICYmIEFycmF5LmlzQXJyYXkoaGl0Lml0
ZW1zKSAmJiBoaXQuaXRlbXMubGVuZ3RoKSB7CiAgICAgICAgICAgICAgICAgICAgICAgIGFsbENsaXBz
ID0gaGl0Lml0ZW1zLnNsaWNlKCk7CiAgICAgICAgICAgICAgICAgICAgICAgIGRpc2tUb3RhbCA9IE51
bWJlcihoaXQudG90YWwpIHx8IGhpdC5pdGVtcy5sZW5ndGg7CiAgICAgICAgICAgICAgICAgICAgICAg
IHdpbmRvdy5fX2RhdGFSZWFkeSA9IHRydWU7CiAgICAgICAgICAgICAgICAgICAgICAgIHNldEJvb3RM
b2FkaW5nKGZhbHNlKTsKICAgICAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICB9IGNhdGNo
IHt9CiAgICAgICAgICAgIH0gZWxzZSBpZiAod3JhcCkgewogICAgICAgICAgICAgICAgd3JhcC5jbGFz
c0xpc3QuYWRkKCdvcGVuJyk7CiAgICAgICAgICAgICAgICBpZiAoc3JjaCAmJiBzcmNoLnZhbHVlKQog
ICAgICAgICAgICAgICAgICAgIHF1ZXJ5ID0gc3JjaC52YWx1ZTsKICAgICAgICAgICAgfQogICAgICAg
ICAgICB0b2RheU9ubHkgPSBmYWxzZTsKICAgICAgICAgICAgdHJ5IHsKICAgICAgICAgICAgICAgIGNv
bnN0IGJ0blRvZGF5ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi10b2RheScpOwogICAgICAg
ICAgICAgICAgaWYgKGJ0blRvZGF5KSBidG5Ub2RheS5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAg
ICAgICAgICB9IGNhdGNoIHt9CiAgICAgICAgICAgIGN1clRhYiA9ICdhbGwnOwogICAgICAgICAgICBs
b2FkaW5nTW9yZSA9IGZhbHNlOwogICAgICAgICAgICBtYXJrVGFiKCdhbGwnKTsKICAgICAgICAgICAg
Ly8g5LiN6KaBIGFoaygnYmx1clBhbmVsJynvvJrkvJrot58gU2hvd1BhbmVsIOaKoueEpueCue+8jFdp
bitWLz8/IOmDveWuueaYk+mXquOAgeS5sei3swogICAgICAgICAgICBpZiAod2luZG93Ll9fcGVuZGlu
Z1NrZWxUaW1lcikgY2xlYXJUaW1lb3V0KHdpbmRvdy5fX3BlbmRpbmdTa2VsVGltZXIpOwogICAgICAg
ICAgICB3aW5kb3cuX19wZW5kaW5nU2tlbFNpbmNlID0gRGF0ZS5ub3coKTsKICAgICAgICAgICAgd2lu
ZG93Ll9fcGVuZGluZ1NrZWxUaW1lciA9IHNldFRpbWVvdXQoKCkgPT4gewogICAgICAgICAgICAgICAg
d2luZG93Ll9fcGVuZGluZ1NrZWxUaW1lciA9IDA7CiAgICAgICAgICAgICAgICBpZiAoIXdpbmRvdy5f
X2RhdGFSZWFkeSkgc2V0Qm9vdExvYWRpbmcodHJ1ZSk7CiAgICAgICAgICAgIH0sIDE4MCk7CiAgICAg
ICAgICAgIHJlbmRlcigpOwogICAgICAgIH0gY2F0Y2gge30KICAgICAgICBzZWxlY3RGaXJzdE9uU2hv
dyA9IHRydWU7CiAgICAgICAgbG9jYXRlQWN0aXZlID0gZmFsc2U7CiAgICAgICAgdXBkYXRlTG9jYXRl
QnRuKCk7CiAgICAgICAgY2xlYXJNdWx0aSgpOwogICAgICAgIGNvbnN0IHZpcyA9IHZpc2libGVMaXN0
KCk7CiAgICAgICAgaWYgKHZpcy5sZW5ndGgpIHsKICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IHZpc1sw
XS5pZDsKICAgICAgICAgICAgcmFuZ2VBbmNob3JJZCA9IHNlbGVjdGVkSWQ7CiAgICAgICAgICAgIHJh
bmdlQW5jaG9yQ2xpY2tlZCA9IGZhbHNlOwogICAgICAgICAgICBsaXN0RWwuc2Nyb2xsVG9wID0gMDsK
ICAgICAgICB9CiAgICAgICAgc3luY0l0ZW1IaWdobGlnaHQoKTsKICAgIH07CgogICAgZnVuY3Rpb24g
Y3R4QmluZChpZCwgZm4pIHsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChpZCkuYWRkRXZl
bnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsK
ICAgICAgICAgICAgaWYgKGN0eENsaXApIGZuKGN0eENsaXApOwogICAgICAgICAgICBoaWRlQ3R4KCk7
CiAgICAgICAgfSk7CiAgICB9CiAgICBjdHhCaW5kKCdjLWNvcHknLCAgYyA9PiBhaGsoJ2NvcHlCeUlk
JywgICAgIFN0cmluZyhjLmlkKSkpOwogICAgY3R4QmluZCgnYy1wYXN0ZScsIGMgPT4gewogICAgICAg
IG1hcmtQYXN0ZWRMb2NhbChjLmlkKTsKICAgICAgICBhaGsoJ3Bhc3RlJywgU3RyaW5nKGMuaWQpKTsK
ICAgIH0pOwogICAgY3R4QmluZCgnYy1waW4nLCAgIGMgPT4gYWhrKCdwaW4nLCAgICAgICAgICAgU3Ry
aW5nKGMuaWQpKSk7CiAgICBjdHhCaW5kKCdjLXRvcCcsICAgYyA9PiBhaGsoJ21vdmVUb1RvcCcsICAg
ICBTdHJpbmcoYy5pZCkpKTsKICAgIGN0eEJpbmQoJ2MtY2xlYXItcGFzdGVkJywgYyA9PiBhaGsoJ2Ns
ZWFyUGFzdGVkJywgU3RyaW5nKGMuaWQpKSk7CiAgICBjdHhCaW5kKCdjLWRlbCcsICAgYyA9PiBhaGso
J2RlbGV0ZScsICAgICAgICBTdHJpbmcoYy5pZCkpKTsKICAgIGN0eEJpbmQoJ2MtdGl0bGUnLCBjID0+
IG9wZW5UaXRsZURsZyhjKSk7CiAgICBjdHhCaW5kKCdjLW1lcmdlJywgYyA9PiB7CiAgICAgICAgY29u
c3QgaWRzID0gKG11bHRpSWRzLmxlbmd0aCA+PSAyKSA/IG11bHRpSWRzLnNsaWNlKCkgOiBbXTsKICAg
ICAgICBpZiAoaWRzLmxlbmd0aCA8IDIpIHJldHVybjsKICAgICAgICBpZiAoIWlkcy5pbmNsdWRlcygr
Yy5pZCkpIGlkcy5wdXNoKCtjLmlkKTsKICAgICAgICBhaGsoJ21lcmdlRmF2JywgaWRzLmpvaW4oJywn
KSk7CiAgICAgICAgY2xlYXJNdWx0aSgpOwogICAgfSk7CiAgICBjdHhCaW5kKCdjLXVubWVyZ2UnLCBj
ID0+IHsKICAgICAgICBhaGsoJ3VubWVyZ2VGYXYnLCBTdHJpbmcoYy5pZCkpOwogICAgICAgIGNsZWFy
TXVsdGkoKTsKICAgIH0pOwoKICAgIGNvbnN0IHRpdGxlRGxnID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ3RpdGxlLWRsZycpOwogICAgY29uc3QgdGl0bGVJbnB1dCA9IGRvY3VtZW50LmdldEVsZW1lbnRC
eUlkKCd0aXRsZS1pbnB1dCcpOwogICAgbGV0IHRpdGxlRGxnQ2xpcCA9IG51bGw7CiAgICBmdW5jdGlv
biBjbG9zZVRpdGxlRGxnKCkgewogICAgICAgIGlmICh0aXRsZURsZykgdGl0bGVEbGcuY2xhc3NMaXN0
LnJlbW92ZSgnb24nKTsKICAgICAgICB0aXRsZURsZ0NsaXAgPSBudWxsOwogICAgfQogICAgZnVuY3Rp
b24gb3BlblRpdGxlRGxnKGMpIHsKICAgICAgICBoaWRlQ3R4KCk7CiAgICAgICAgdGl0bGVEbGdDbGlw
ID0gYzsKICAgICAgICBpZiAodGl0bGVJbnB1dCkgdGl0bGVJbnB1dC52YWx1ZSA9IFN0cmluZyhjLmZh
dlRpdGxlIHx8ICcnKS50cmltKCk7CiAgICAgICAgaWYgKHRpdGxlRGxnKSB0aXRsZURsZy5jbGFzc0xp
c3QuYWRkKCdvbicpOwogICAgICAgIGFoaygnZm9jdXNQYW5lbCcpOwogICAgICAgIHJlcXVlc3RBbmlt
YXRpb25GcmFtZSgoKSA9PiB7CiAgICAgICAgICAgIHRyeSB7IHRpdGxlSW5wdXQuZm9jdXMoKTsgdGl0
bGVJbnB1dC5zZWxlY3QoKTsgfSBjYXRjaCB7fQogICAgICAgIH0pOwogICAgfQogICAgaWYgKHRpdGxl
RGxnKSB7CiAgICAgICAgdGl0bGVEbGcuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAg
ICAgICAgICAgaWYgKGUudGFyZ2V0ID09PSB0aXRsZURsZykgY2xvc2VUaXRsZURsZygpOwogICAgICAg
IH0pOwogICAgfQogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RpdGxlLWNhbmNlbCcpPy5hZGRF
dmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAg
ICAgICAgY2xvc2VUaXRsZURsZygpOwogICAgICAgIGFoaygnYmx1clBhbmVsJyk7CiAgICB9KTsKICAg
IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0aXRsZS1vaycpPy5hZGRFdmVudExpc3RlbmVyKCdjbGlj
aycsIGUgPT4gewogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgaWYgKCF0aXRsZURs
Z0NsaXApIHJldHVybjsKICAgICAgICBjb25zdCB0ID0gU3RyaW5nKHRpdGxlSW5wdXQ/LnZhbHVlIHx8
ICcnKS50cmltKCkuc2xpY2UoMCwgODApOwogICAgICAgIGNvbnN0IGlkID0gU3RyaW5nKHRpdGxlRGxn
Q2xpcC5pZCk7CiAgICAgICAgLy8gT3B0aW1pc3RpYyBsb2NhbCB1cGRhdGUKICAgICAgICBjb25zdCBo
aXQgPSBhbGxDbGlwcy5maW5kKHggPT4gK3guaWQgPT09ICtpZCk7CiAgICAgICAgaWYgKGhpdCkgaGl0
LmZhdlRpdGxlID0gdDsKICAgICAgICB0aXRsZURsZ0NsaXAuZmF2VGl0bGUgPSB0OwogICAgICAgIGNs
b3NlVGl0bGVEbGcoKTsKICAgICAgICBhaGsoJ3NldEZhdlRpdGxlJywgaWQsIHQpOwogICAgICAgIGFo
aygnYmx1clBhbmVsJyk7CiAgICAgICAgcmVuZGVyKCk7CiAgICB9KTsKICAgIHRpdGxlSW5wdXQ/LmFk
ZEV2ZW50TGlzdGVuZXIoJ2tleWRvd24nLCBlID0+IHsKICAgICAgICBpZiAoZS5rZXkgPT09ICdFbnRl
cicpIHsKICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICBlLnN0b3BQcm9w
YWdhdGlvbigpOwogICAgICAgICAgICBlLnN0b3BJbW1lZGlhdGVQcm9wYWdhdGlvbigpOwogICAgICAg
ICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGl0bGUtb2snKT8uY2xpY2soKTsKICAgICAgICAg
ICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBpZiAoZS5rZXkgPT09ICdFc2NhcGUnKSB7CiAgICAg
ICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsK
ICAgICAgICAgICAgY2xvc2VUaXRsZURsZygpOwogICAgICAgICAgICBhaGsoJ2JsdXJQYW5lbCcpOwog
ICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAg
ICB9LCB0cnVlKTsKCiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGFicycpLmFkZEV2ZW50TGlz
dGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgY29uc3QgdGFiID0gZS50YXJnZXQuY2xvc2VzdCgn
LnRhYicpOwogICAgICAgIGlmICghdGFiIHx8IGUudGFyZ2V0LmNsb3Nlc3QoJyN0YWItYWN0aW9ucycp
KSByZXR1cm47CiAgICAgICAgc2V0VGFiKHRhYi5kYXRhc2V0LnRhYik7CiAgICB9KTsKCiAgICBjb25z
dCBzcmNoV3JhcCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gtd3JhcCcpOwogICAgY29u
c3QgYnRuU2VhcmNoID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi1zZWFyY2gnKTsKICAgIGNv
bnN0IGJ0bkxvY2F0ZSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tbG9jYXRlJyk7CiAgICBj
b25zdCBidG5Ub2RheSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tdG9kYXknKTsKICAgIGNv
bnN0IHNyY2ggPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNoJyk7CiAgICBjb25zdCBzY2xy
ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaC1jbHInKTsKICAgIGxldCBkZWI7CgogICAg
dXBkYXRlTG9jYXRlQnRuKCk7CiAgICBpZiAoYnRuTG9jYXRlKSB7CiAgICAgICAgYnRuTG9jYXRlLmFk
ZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9u
KCk7CiAgICAgICAgICAgIGp1bXBUb0xhc3RQYXN0ZSgpOwogICAgICAgIH0pOwogICAgfQoKICAgIGJ0
blRvZGF5LmFkZEV2ZW50TGlzdGVuZXIoJ21vdXNlZG93bicsIGUgPT4gewogICAgICAgIGUucHJldmVu
dERlZmF1bHQoKTsKICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgfSk7CiAgICBidG5Ub2Rh
eS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9u
KCk7CiAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgIHRvZGF5T25seSA9ICF0b2RheU9u
bHk7CiAgICAgICAgYnRuVG9kYXkuY2xhc3NMaXN0LnRvZ2dsZSgnb24nLCB0b2RheU9ubHkpOwogICAg
ICAgIGxpc3RFbC5zY3JvbGxUb3AgPSAwOwogICAgICAgIHJlcXVlc3RWaWV3KCk7CiAgICAgICAgdHJ5
IHsgc3JjaC5mb2N1cygpOyB9IGNhdGNoIHt9CiAgICB9KTsKCiAgICBmdW5jdGlvbiBvcGVuU2VhcmNo
KCkgewogICAgICAgIGlmIChzcmNoV3JhcC5jbGFzc0xpc3QuY29udGFpbnMoJ29wZW4nKSkgewogICAg
ICAgICAgICBhaGsoJ2ZvY3VzUGFuZWwnKTsKICAgICAgICAgICAgdHJ5IHsgc3JjaC5mb2N1cygpOyB9
IGNhdGNoIHt9CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgc3JjaFdyYXAuY2xh
c3NMaXN0LmFkZCgnb3BlbicpOwogICAgICAgIC8vIERlZmF1bHQ6IOaJgOaciemhteaJk+W8gOaQnOe0
ouaXtum7mOiupOaQnOWFqOmDqAogICAgICAgIGNvbnN0IHdhbnRUb2RheSA9IGZhbHNlOwogICAgICAg
IGlmICh0b2RheU9ubHkgIT09IHdhbnRUb2RheSkgewogICAgICAgICAgICB0b2RheU9ubHkgPSB3YW50
VG9kYXk7CiAgICAgICAgICAgIGJ0blRvZGF5LmNsYXNzTGlzdC50b2dnbGUoJ29uJywgdG9kYXlPbmx5
KTsKICAgICAgICAgICAgbGlzdEVsLnNjcm9sbFRvcCA9IDA7CiAgICAgICAgICAgIHJlcXVlc3RWaWV3
KCk7CiAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgYnRuVG9kYXkuY2xhc3NMaXN0LnRvZ2dsZSgn
b24nLCB0b2RheU9ubHkpOwogICAgICAgIH0KICAgICAgICBhaGsoJ2ZvY3VzUGFuZWwnKTsKICAgICAg
ICByZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4gewogICAgICAgICAgICB0cnkgeyBzcmNoLmZvY3Vz
KCk7IH0gY2F0Y2gge30KICAgICAgICB9KTsKICAgIH0KICAgIGZ1bmN0aW9uIGNsb3NlU2VhcmNoVWko
KSB7CiAgICAgICAgc3JjaFdyYXAuY2xhc3NMaXN0LnJlbW92ZSgnb3BlbicpOwogICAgICAgIGlmICgh
c3JjaC52YWx1ZSkgewogICAgICAgICAgICBzcmNoLmNsYXNzTGlzdC5yZW1vdmUoJ2hhcy12YWwnKTsK
ICAgICAgICAgICAgc2Nsci5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOwogICAgICAgICAgICAvLyBMZWF2
aW5nIHNlYXJjaCB3aXRoIGVtcHR5IHF1ZXJ5IOKGkiBkcm9wIHRvZGF5IGZpbHRlcgogICAgICAgICAg
ICBpZiAodG9kYXlPbmx5KSB7CiAgICAgICAgICAgICAgICB0b2RheU9ubHkgPSBmYWxzZTsKICAgICAg
ICAgICAgICAgIGJ0blRvZGF5LmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgICAgICAgICBy
ZXF1ZXN0VmlldygpOwogICAgICAgICAgICB9CiAgICAgICAgfQogICAgfQogICAgd2luZG93Ll9fb3Bl
blNlYXJjaCA9IG9wZW5TZWFyY2g7CiAgICB3aW5kb3cuX19wcmVwVHlwZVNlYXJjaCA9ICgpID0+IHsK
ICAgICAgICB0cnkgewogICAgICAgICAgICBjb25zdCB3cmFwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ3NlYXJjaC13cmFwJyk7CiAgICAgICAgICAgIGNvbnN0IHMgPSBkb2N1bWVudC5nZXRFbGVtZW50
QnlJZCgnc2VhcmNoJyk7CiAgICAgICAgICAgIGlmICh3cmFwICYmICF3cmFwLmNsYXNzTGlzdC5jb250
YWlucygnb3BlbicpKSB7CiAgICAgICAgICAgICAgICB3cmFwLmNsYXNzTGlzdC5hZGQoJ29wZW4nKTsK
ICAgICAgICAgICAgICAgIHRyeSB7CiAgICAgICAgICAgICAgICAgICAgY29uc3Qgd2FudFRvZGF5ID0g
ZmFsc2U7CiAgICAgICAgICAgICAgICAgICAgaWYgKHR5cGVvZiB0b2RheU9ubHkgIT09ICd1bmRlZmlu
ZWQnICYmIHRvZGF5T25seSAhPT0gd2FudFRvZGF5KSB7CiAgICAgICAgICAgICAgICAgICAgICAgIHRv
ZGF5T25seSA9IHdhbnRUb2RheTsKICAgICAgICAgICAgICAgICAgICAgICAgaWYgKHR5cGVvZiBidG5U
b2RheSAhPT0gJ3VuZGVmaW5lZCcgJiYgYnRuVG9kYXkpIGJ0blRvZGF5LmNsYXNzTGlzdC50b2dnbGUo
J29uJywgdG9kYXlPbmx5KTsKICAgICAgICAgICAgICAgICAgICAgICAgaWYgKHR5cGVvZiBsaXN0RWwg
IT09ICd1bmRlZmluZWQnICYmIGxpc3RFbCkgbGlzdEVsLnNjcm9sbFRvcCA9IDA7CiAgICAgICAgICAg
ICAgICAgICAgICAgIGlmICh0eXBlb2YgcmVxdWVzdFZpZXcgPT09ICdmdW5jdGlvbicpIHNldFRpbWVv
dXQocmVxdWVzdFZpZXcsIDApOwogICAgICAgICAgICAgICAgICAgIH0gZWxzZSBpZiAodHlwZW9mIGJ0
blRvZGF5ICE9PSAndW5kZWZpbmVkJyAmJiBidG5Ub2RheSkgewogICAgICAgICAgICAgICAgICAgICAg
ICBidG5Ub2RheS5jbGFzc0xpc3QudG9nZ2xlKCdvbicsICEhdG9kYXlPbmx5KTsKICAgICAgICAgICAg
ICAgICAgICB9CiAgICAgICAgICAgICAgICB9IGNhdGNoIHt9CiAgICAgICAgICAgIH0KICAgICAgICAg
ICAgLy8gPz8g6ZWc5YOP5pCc57Si77ya5LiN6KaBIGZvY3Vz77yM6YG/5YWN5oqi6LWw5Y6f57yW6L6R
5qGG5YWJ5qCHCiAgICAgICAgfSBjYXRjaCB7fQogICAgfTsKICAgIHdpbmRvdy5fX3R5cGVTZWFyY2gg
PSAoY2gpID0+IHsKICAgICAgICB0cnkgewogICAgICAgICAgICB3aW5kb3cuX19wcmVwVHlwZVNlYXJj
aCAmJiB3aW5kb3cuX19wcmVwVHlwZVNlYXJjaCgpOwogICAgICAgICAgICBjb25zdCBzID0gZG9jdW1l
bnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaCcpOwogICAgICAgICAgICBpZiAoIXMpIHJldHVybjsKICAg
ICAgICAgICAgcy52YWx1ZSA9IFN0cmluZyhzLnZhbHVlIHx8ICcnKSArIFN0cmluZyhjaCA9PSBudWxs
ID8gJycgOiBjaCk7CiAgICAgICAgICAgIHMuY2xhc3NMaXN0LnRvZ2dsZSgnaGFzLXZhbCcsICEhcy52
YWx1ZSk7CiAgICAgICAgICAgIHMuZGlzcGF0Y2hFdmVudChuZXcgRXZlbnQoJ2lucHV0JywgeyBidWJi
bGVzOiB0cnVlIH0pKTsKICAgICAgICB9IGNhdGNoIHt9CiAgICB9OwogICAgd2luZG93Ll9fYmtzcFNl
YXJjaCA9ICgpID0+IHsKICAgICAgICB0cnkgewogICAgICAgICAgICB3aW5kb3cuX19wcmVwVHlwZVNl
YXJjaCAmJiB3aW5kb3cuX19wcmVwVHlwZVNlYXJjaCgpOwogICAgICAgICAgICBjb25zdCBzID0gZG9j
dW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaCcpOwogICAgICAgICAgICBpZiAoIXMpIHJldHVybjsK
ICAgICAgICAgICAgY29uc3QgdiA9IFN0cmluZyhzLnZhbHVlIHx8ICcnKTsKICAgICAgICAgICAgcy52
YWx1ZSA9IHYubGVuZ3RoID8gdi5zbGljZSgwLCAtMSkgOiAnJzsKICAgICAgICAgICAgcy5jbGFzc0xp
c3QudG9nZ2xlKCdoYXMtdmFsJywgISFzLnZhbHVlKTsKICAgICAgICAgICAgcy5kaXNwYXRjaEV2ZW50
KG5ldyBFdmVudCgnaW5wdXQnLCB7IGJ1YmJsZXM6IHRydWUgfSkpOwogICAgICAgIH0gY2F0Y2gge30K
ICAgIH07CiAgICB3aW5kb3cuX19zZXRTZWFyY2hRdWVyeSA9IChxKSA9PiB7CiAgICAgICAgdHJ5IHsK
ICAgICAgICAgICAgY29uc3QgcyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gnKTsKICAg
ICAgICAgICAgaWYgKCFzKSByZXR1cm47CiAgICAgICAgICAgIC8vIOaJk+Wtl+WNs+aXtuS4iuWxj++8
jOS4juejgeebmOaQnOe0ouino+iApgogICAgICAgICAgICBzLnZhbHVlID0gU3RyaW5nKHEgPT0gbnVs
bCA/ICcnIDogcSk7CiAgICAgICAgICAgIHMuY2xhc3NMaXN0LnRvZ2dsZSgnaGFzLXZhbCcsICEhcy52
YWx1ZSk7CiAgICAgICAgICAgIGNvbnN0IHNjbHIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2Vh
cmNoLWNscicpOwogICAgICAgICAgICBpZiAoc2Nscikgc2Nsci5zdHlsZS5kaXNwbGF5ID0gcy52YWx1
ZSA/ICdibG9jaycgOiAnbm9uZSc7CiAgICAgICAgICAgIHF1ZXJ5ID0gcy52YWx1ZTsKICAgICAgICAg
ICAgdHJ5IHsKICAgICAgICAgICAgICAgIGNvbnN0IHdyYXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJ
ZCgnc2VhcmNoLXdyYXAnKTsKICAgICAgICAgICAgICAgIGlmICh3cmFwICYmICF3cmFwLmNsYXNzTGlz
dC5jb250YWlucygnb3BlbicpKQogICAgICAgICAgICAgICAgICAgIHdpbmRvdy5fX3ByZXBUeXBlU2Vh
cmNoICYmIHdpbmRvdy5fX3ByZXBUeXBlU2VhcmNoKCk7CiAgICAgICAgICAgICAgICBlbHNlIGlmICh3
cmFwKQogICAgICAgICAgICAgICAgICAgIHdyYXAuY2xhc3NMaXN0LmFkZCgnb3BlbicpOwogICAgICAg
ICAgICB9IGNhdGNoIHt9CiAgICAgICAgICAgIHRyeSB7CiAgICAgICAgICAgICAgICBjb25zdCBjbnQg
PSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYmFyLXR4dCcpOwogICAgICAgICAgICAgICAgaWYgKGNu
dCAmJiBTdHJpbmcocXVlcnkgfHwgJycpLnRyaW0oKSkKICAgICAgICAgICAgICAgICAgICBjbnQudGV4
dENvbnRlbnQgPSB2aXNpYmxlTGlzdCgpLmxlbmd0aCArICcg5p2hJzsKICAgICAgICAgICAgfSBjYXRj
aCB7fQogICAgICAgIH0gY2F0Y2gge30KICAgIH07CiAgICAvLyBDYXB0dXJlIEN0cmwrRiBpbnNpZGUg
V2ViVmlldyAoQ2hyb21pdW0gZmluZCBpcyBkaXNhYmxlZCwgYnV0IHN0aWxsIGhhbmRsZSBoZXJlKQog
ICAgZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5lcigna2V5ZG93bicsIGUgPT4gewogICAgICAgIGlmICgo
ZS5jdHJsS2V5IHx8IGUubWV0YUtleSkgJiYgIWUuYWx0S2V5ICYmIChlLmtleSA9PT0gJ2YnIHx8IGUu
a2V5ID09PSAnRicpKSB7CiAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAg
ZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAgb3BlblNlYXJjaCgpOwogICAgICAgIH0KICAg
IH0sIHRydWUpOwogICAgYnRuU2VhcmNoLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAg
ICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICBvcGVuU2VhcmNoKCk7CiAgICB9KTsKICAg
IGxldCBfX3NyY2hDb21wb3NpbmcgPSBmYWxzZTsKICAgIGNvbnN0IF9fZmx1c2hTZWFyY2hJbnB1dCA9
ICgpID0+IHsKICAgICAgICBxdWVyeSA9IHNyY2gudmFsdWU7CiAgICAgICAgc3JjaC5jbGFzc0xpc3Qu
dG9nZ2xlKCdoYXMtdmFsJywgISFxdWVyeSk7CiAgICAgICAgc2Nsci5zdHlsZS5kaXNwbGF5ID0gcXVl
cnkgPyAnYmxvY2snIDogJ25vbmUnOwogICAgICAgIGxpc3RFbC5zY3JvbGxUb3AgPSAwOwogICAgICAg
IGNsZWFyVGltZW91dChkZWIpOwogICAgICAgIGRlYiA9IHNldFRpbWVvdXQocmVxdWVzdFZpZXcsIDE4
MCk7CiAgICB9OwogICAgc3JjaC5hZGRFdmVudExpc3RlbmVyKCdjb21wb3NpdGlvbnN0YXJ0JywgKCkg
PT4geyBfX3NyY2hDb21wb3NpbmcgPSB0cnVlOyB9KTsKICAgIHNyY2guYWRkRXZlbnRMaXN0ZW5lcign
Y29tcG9zaXRpb25lbmQnLCAoKSA9PiB7CiAgICAgICAgX19zcmNoQ29tcG9zaW5nID0gZmFsc2U7CiAg
ICAgICAgX19mbHVzaFNlYXJjaElucHV0KCk7CiAgICB9KTsKICAgIHNyY2guYWRkRXZlbnRMaXN0ZW5l
cignaW5wdXQnLCAoKSA9PiB7CiAgICAgICAgaWYgKF9fc3JjaENvbXBvc2luZykgewogICAgICAgICAg
ICBxdWVyeSA9IHNyY2gudmFsdWU7CiAgICAgICAgICAgIHNyY2guY2xhc3NMaXN0LnRvZ2dsZSgnaGFz
LXZhbCcsICEhcXVlcnkpOwogICAgICAgICAgICBzY2xyLnN0eWxlLmRpc3BsYXkgPSBxdWVyeSA/ICdi
bG9jaycgOiAnbm9uZSc7CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgX19mbHVz
aFNlYXJjaElucHV0KCk7CiAgICB9KTsKICAgIHNyY2guYWRkRXZlbnRMaXN0ZW5lcignZm9jdXMnLCAo
KSA9PiB7CiAgICAgICAgLy8gSWRlbXBvdGVudCBvbiBBSEsgc2lkZSDigJQgc2FmZSwgYnV0IGF2b2lk
IHNwYW1taW5nIGR1cmluZyBJTUUKICAgICAgICB0cnkgeyBhaGsoJ2ZvY3VzUGFuZWwnKTsgfSBjYXRj
aCB7fQogICAgfSk7CiAgICBzcmNoLmFkZEV2ZW50TGlzdGVuZXIoJ2JsdXInLCAoKSA9PiB7CiAgICAg
ICAgc2V0VGltZW91dCgoKSA9PiB7CiAgICAgICAgICAgIGlmIChkb2N1bWVudC5hY3RpdmVFbGVtZW50
ID09PSBzcmNoKSByZXR1cm47CiAgICAgICAgICAgIGlmIChkb2N1bWVudC5hY3RpdmVFbGVtZW50ID09
PSBzY2xyIHx8IChzY2xyICYmIHNjbHIuY29udGFpbnMoZG9jdW1lbnQuYWN0aXZlRWxlbWVudCkpKSBy
ZXR1cm47CiAgICAgICAgICAgIGlmIChkb2N1bWVudC5hY3RpdmVFbGVtZW50ID09PSBidG5Ub2RheSB8
fCAoYnRuVG9kYXkgJiYgYnRuVG9kYXkuY29udGFpbnMoZG9jdW1lbnQuYWN0aXZlRWxlbWVudCkpKSBy
ZXR1cm47CiAgICAgICAgICAgIC8vIElNRSBjYW5kaWRhdGUgVUkgc3RlYWxzIGZvY3VzIGJyaWVmbHkg
4oCUIGtlZXAgc2VhcmNoIGlmIHN0aWxsIGNvbXBvc2luZwogICAgICAgICAgICBpZiAoX19zcmNoQ29t
cG9zaW5nKSByZXR1cm47CiAgICAgICAgICAgIGNsb3NlU2VhcmNoVWkoKTsKICAgICAgICAgICAgYWhr
KCdibHVyUGFuZWwnKTsKICAgICAgICB9LCAyODApOwogICAgfSk7CiAgICBzcmNoLmFkZEV2ZW50TGlz
dGVuZXIoJ2tleWRvd24nLCBlID0+IHsKICAgICAgICAvLyBDdHJsK0kgLyBDdHJsK0s6IG1vdmUgY2xp
cCBzZWxlY3Rpb24gKG5vdCBpbnNlcnQgY2hhciAvIGJyb3dzZXIgc2hvcnRjdXQpCiAgICAgICAgaWYg
KChlLmN0cmxLZXkgfHwgZS5tZXRhS2V5KSAmJiAoZS5rZXkgPT09ICdpJyB8fCBlLmtleSA9PT0gJ0kn
KSkgewogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgIGUuc3RvcFByb3Bh
Z2F0aW9uKCk7CiAgICAgICAgICAgIHdpbmRvdy5fX25hdiAmJiB3aW5kb3cuX19uYXYoJ3VwJyk7CiAg
ICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAgICAgICAgaWYgKChlLmN0cmxLZXkgfHwgZS5tZXRh
S2V5KSAmJiAoZS5rZXkgPT09ICdrJyB8fCBlLmtleSA9PT0gJ0snKSkgewogICAgICAgICAgICBlLnBy
ZXZlbnREZWZhdWx0KCk7CiAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAg
IHdpbmRvdy5fX25hdiAmJiB3aW5kb3cuX19uYXYoJ2Rvd24nKTsKICAgICAgICAgICAgcmV0dXJuOwog
ICAgICAgIH0KICAgICAgICBpZiAoZS5rZXkgPT09ICdBcnJvd0Rvd24nKSB7CiAgICAgICAgICAgIGUu
cHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAg
ICAgd2luZG93Ll9fbmF2ICYmIHdpbmRvdy5fX25hdignZG93bicpOwogICAgICAgICAgICByZXR1cm47
CiAgICAgICAgfQogICAgICAgIGlmIChlLmtleSA9PT0gJ0Fycm93VXAnKSB7CiAgICAgICAgICAgIGUu
cHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAg
ICAgd2luZG93Ll9fbmF2ICYmIHdpbmRvdy5fX25hdigndXAnKTsKICAgICAgICAgICAgcmV0dXJuOwog
ICAgICAgIH0KICAgICAgICBpZiAoZS5rZXkgPT09ICdFc2NhcGUnKSB7CiAgICAgICAgICAgIGUucHJl
dmVudERlZmF1bHQoKTsKICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAgICAg
Ly8gQWx3YXlzIGRpc21pc3MgdGhlIHdob2xlIHBhbmVsIChub3QganVzdCB0aGUgc2VhcmNoIGZpZWxk
KQogICAgICAgICAgICBpZiAoIXBpbm5lZFVJKSBhaGsoJ2hpZGUnKTsKICAgICAgICAgICAgcmV0dXJu
OwogICAgICAgIH0KICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgfSk7CiAgICBzY2xyLmFk
ZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsK
ICAgICAgICBzcmNoLnZhbHVlID0gcXVlcnkgPSAnJzsKICAgICAgICBzY2xyLnN0eWxlLmRpc3BsYXkg
PSAnbm9uZSc7CiAgICAgICAgc3JjaC5jbGFzc0xpc3QucmVtb3ZlKCdoYXMtdmFsJyk7CiAgICAgICAg
cmVxdWVzdFZpZXcoKTsKICAgICAgICBhaGsoJ2ZvY3VzUGFuZWwnKTsKICAgICAgICBzcmNoLmZvY3Vz
KCk7CiAgICB9KTsKCiAgICBjb25zdCBUQUJfTkFNRVMgPSB7IGFsbDogJ+WFqOmDqCcsIHRleHQ6ICfm
lofmnKwnLCBpbWFnZTogJ+WbvuWDjycsIGZpbGU6ICfmlofku7YnLCBwaW5uZWQ6ICfmlLbol48nIH07
CiAgICBjb25zdCBjbHJEbGcgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2xyLWRsZycpOwogICAg
Y29uc3QgY2xyQWxsQ2IgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2xyLWFsbCcpOwogICAgZnVu
Y3Rpb24gb3BlbkNsZWFyRGxnKCkgewogICAgICAgIGNvbnN0IG5hbWUgPSBUQUJfTkFNRVNbY3VyVGFi
XSB8fCAn5b2T5YmNJzsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2xyLXRpdGxlJyku
dGV4dENvbnRlbnQgPSAn5riF56m644CMJyArIG5hbWUgKyAn44CN77yfJzsKICAgICAgICBkb2N1bWVu
dC5nZXRFbGVtZW50QnlJZCgnY2xyLWRlc2MnKS50ZXh0Q29udGVudCA9IGN1clRhYiA9PT0gJ3Bpbm5l
ZCcKICAgICAgICAgICAgPyAn6buY6K6k5LuF5riF56m65b2T5aSp55qE5pS26JeP6aG544CC5Yu+6YCJ
44CM5riF56m65omA5pyJ44CN5Y+v5riF6Zmk6K+l6YCJ6aG55Y2h5YWo6YOo5YaF5a6544CCJwogICAg
ICAgICAgICA6ICfku4XmuIXnqbrlvZPliY3pgInpobnljaHjgILpu5jorqTlj6rmuIXlvZPlpKnvvJvm
lLbol4/pobnkuI3kvJrooqvmuIXpmaTjgILli77pgInjgIzmuIXnqbrmiYDmnInjgI3lj6/muIXpmaTo
r6XpgInpobnljaHlhajpg6jml6XmnJ/jgIInOwogICAgICAgIGNsckFsbENiLmNoZWNrZWQgPSBmYWxz
ZTsKICAgICAgICBjbHJEbGcuY2xhc3NMaXN0LmFkZCgnb24nKTsKICAgIH0KICAgIGZ1bmN0aW9uIGNs
b3NlQ2xlYXJEbGcoKSB7CiAgICAgICAgY2xyRGxnLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICB9
CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLWNscicpLmFkZEV2ZW50TGlzdGVuZXIoJ2Ns
aWNrJywgZSA9PiB7CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICBvcGVuQ2xlYXJE
bGcoKTsKICAgIH0pOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Nsci1jYW5jZWwnKS5hZGRF
dmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAg
ICAgICAgY2xvc2VDbGVhckRsZygpOwogICAgfSk7CiAgICBjbHJEbGcuYWRkRXZlbnRMaXN0ZW5lcign
Y2xpY2snLCBlID0+IHsKICAgICAgICBpZiAoZS50YXJnZXQgPT09IGNsckRsZykgY2xvc2VDbGVhckRs
ZygpOwogICAgfSk7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2xyLW9rJykuYWRkRXZlbnRM
aXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAg
IGNvbnN0IHNjb3BlID0gY2xyQWxsQ2IuY2hlY2tlZCA/ICdhbGwnIDogJ3RvZGF5JzsKICAgICAgICBj
bG9zZUNsZWFyRGxnKCk7CiAgICAgICAgYWhrKCdjbGVhcicsIGN1clRhYiwgc2NvcGUpOwogICAgfSk7
CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbXVsdGktY250JykuYWRkRXZlbnRMaXN0ZW5lcign
Y2xpY2snLCBlID0+IHsKICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgIGNsZWFyTXVs
dGkodHJ1ZSk7CiAgICB9KTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tcGluJykuYWRk
RXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwog
ICAgICAgIHBpbm5lZFVJID0gIXBpbm5lZFVJOwogICAgICAgIGUuY3VycmVudFRhcmdldC5jbGFzc0xp
c3QudG9nZ2xlKCdvbicsIHBpbm5lZFVJKTsKICAgICAgICBhaGsoJ3RvZ2dsZVBpbicsIHBpbm5lZFVJ
ID8gJzEnIDogJzAnKTsKICAgIH0pOwoKICAgIHdpbmRvdy5fX3VwZGF0ZUNsaXBzID0gcGF5bG9hZCA9
PiB7CiAgICAgICAgLy8gS2VlcCBwcmV2aW91cyBzY3JvbGwgZm9yIGxvYWQtbW9yZTsgcmVzZXQgd2hl
biBvcGVuaW5nIHBhbmVsIHRvIGZpcnN0IGl0ZW0KICAgICAgICBjb25zdCBrZWVwU2Nyb2xsID0gIXNl
bGVjdEZpcnN0T25TaG93OwogICAgICAgIGNvbnN0IHN0ID0gbGlzdEVsLnNjcm9sbFRvcDsKICAgICAg
ICAvLyDmlbDmja7liLDkuobvvIzlj5bmtoggc2V0VGFiIOaOkumYn+eahOOAjOW7tui/n+mqqOaetuOA
jXRpbWVy77yI6YG/5YWN5a6D5Yiw54K55ZCO5Y+I5byAIHNrZWxldG9u77yJCiAgICAgICAgd2luZG93
Ll9fd2FpdGluZ1ZpZXcgPSBmYWxzZTsKICAgICAgICBpZiAod2luZG93Ll9fcGVuZGluZ1NrZWxUaW1l
cikgewogICAgICAgICAgICBjbGVhclRpbWVvdXQod2luZG93Ll9fcGVuZGluZ1NrZWxUaW1lcik7CiAg
ICAgICAgICAgIHdpbmRvdy5fX3BlbmRpbmdTa2VsVGltZXIgPSAwOwogICAgICAgIH0KICAgICAgICB3
aW5kb3cuX19wZW5kaW5nU2tlbFNpbmNlID0gMDsKICAgICAgICBjb25zdCB3YXNBcHBlbmQgPSBwYXls
b2FkICYmIHBheWxvYWQuYXBwZW5kOwogICAgICAgIGxvYWRpbmdNb3JlID0gZmFsc2U7CiAgICAgICAg
Y29uc3QgcHJldkl0ZW1zID0gYWxsQ2xpcHM7CiAgICAgICAgaWYgKEFycmF5LmlzQXJyYXkocGF5bG9h
ZCkpIHsKICAgICAgICAgICAgYWxsQ2xpcHMgPSBwYXlsb2FkOwogICAgICAgICAgICBkaXNrVG90YWwg
PSBwYXlsb2FkLmxlbmd0aDsKICAgICAgICAgICAgd2luZG93Ll9faG9zdEZpbHRlcmVkID0gZmFsc2U7
CiAgICAgICAgfSBlbHNlIGlmIChwYXlsb2FkICYmIHR5cGVvZiBwYXlsb2FkID09PSAnb2JqZWN0Jykg
ewogICAgICAgICAgICBkaXNrVG90YWwgPSBOdW1iZXIocGF5bG9hZC50b3RhbCkgfHwgMDsKICAgICAg
ICAgICAgY29uc3QgaXRlbXMgPSBBcnJheS5pc0FycmF5KHBheWxvYWQuaXRlbXMpID8gcGF5bG9hZC5p
dGVtcyA6IFtdOwogICAgICAgICAgICBpZiAocGF5bG9hZC5hcHBlbmQpIHsKICAgICAgICAgICAgICAg
IGNvbnN0IHNlZW4gPSBuZXcgU2V0KGFsbENsaXBzLm1hcChjID0+ICtjLmlkKSk7CiAgICAgICAgICAg
ICAgICBpdGVtcy5mb3JFYWNoKGl0ID0+IHsKICAgICAgICAgICAgICAgICAgICBpZiAoIXNlZW4uaGFz
KCtpdC5pZCkpIGFsbENsaXBzLnB1c2goaXQpOwogICAgICAgICAgICAgICAgfSk7CiAgICAgICAgICAg
IH0gZWxzZSB7CiAgICAgICAgICAgICAgICBhbGxDbGlwcyA9IGl0ZW1zOwogICAgICAgICAgICB9CiAg
ICAgICAgICAgIC8vIOS4u+acuuW3suaMiSBxdWVyeSDov4fmu6TvvJrkv6Hku7vnu5PmnpzvvIhwcmV2
aWV3IOS4jeWQq+WFs+mUruWtl+aXtuS5n+S4jeimgeWJjeerr+WGjeadgO+8iQogICAgICAgICAgICBj
b25zdCBwcSA9IHBheWxvYWQucXVlcnkgIT0gbnVsbCA/IFN0cmluZyhwYXlsb2FkLnF1ZXJ5KSA6ICcn
OwogICAgICAgICAgICB3aW5kb3cuX19ob3N0RmlsdGVyZWQgPSAhIShwYXlsb2FkLmZpbHRlcmVkIHx8
IChwcSAmJiBwcS50cmltKCkpKTsKICAgICAgICAgICAgLy8g5pCc57Si5qGG5Lul5omT5a2X6ZWc5YOP
5Li65YeG77yM57ud5LiN6KKr5rue5ZCO55qE56OB55uY57uT5p6c5YaZ5Zue5pen5YWz6ZSu5a2XCiAg
ICAgICAgICAgIHRyeSB7CiAgICAgICAgICAgICAgICBjb25zdCBzID0gZG9jdW1lbnQuZ2V0RWxlbWVu
dEJ5SWQoJ3NlYXJjaCcpOwogICAgICAgICAgICAgICAgaWYgKHMgJiYgU3RyaW5nKHMudmFsdWUgfHwg
JycpLmxlbmd0aCkKICAgICAgICAgICAgICAgICAgICBxdWVyeSA9IHMudmFsdWU7CiAgICAgICAgICAg
ICAgICBlbHNlIGlmIChwcSAhPT0gJycgJiYgIVN0cmluZyhxdWVyeSB8fCAnJykudHJpbSgpKQogICAg
ICAgICAgICAgICAgICAgIHF1ZXJ5ID0gcHE7CiAgICAgICAgICAgIH0gY2F0Y2gge30KICAgICAgICB9
IGVsc2UgewogICAgICAgICAgICBhbGxDbGlwcyA9IFtdOwogICAgICAgICAgICBkaXNrVG90YWwgPSAw
OwogICAgICAgICAgICB3aW5kb3cuX19ob3N0RmlsdGVyZWQgPSBmYWxzZTsKICAgICAgICB9CiAgICAg
ICAgaWYgKCF3YXNBcHBlbmQpIHsKICAgICAgICAgICAgY29uc3QgbWVtUSA9IChwYXlsb2FkICYmIHR5
cGVvZiBwYXlsb2FkID09PSAnb2JqZWN0JyAmJiBwYXlsb2FkLnF1ZXJ5ICE9IG51bGwpCiAgICAgICAg
ICAgICAgICA/IFN0cmluZyhwYXlsb2FkLnF1ZXJ5KSA6IHF1ZXJ5OwogICAgICAgICAgICB2aWV3TWVt
LnNldCh2aWV3TWVtS2V5KGN1clRhYiwgbWVtUSwgdG9kYXlPbmx5KSwgewogICAgICAgICAgICAgICAg
aXRlbXM6IGFsbENsaXBzLnNsaWNlKCksCiAgICAgICAgICAgICAgICB0b3RhbDogZGlza1RvdGFsCiAg
ICAgICAgICAgIH0pOwogICAgICAgIH0KICAgICAgICB3aW5kb3cuX19kYXRhUmVhZHkgPSB0cnVlOwog
ICAgICAgIGNvbnN0IHdhc0Jvb3RMb2FkaW5nID0gYm9vdExvYWRpbmc7CiAgICAgICAgbGV0IHNhbWVQ
YWludCA9IGZhbHNlOwogICAgICAgIGlmICghd2FzQXBwZW5kICYmICF3YXNCb290TG9hZGluZyAmJiBw
cmV2SXRlbXMgJiYgcHJldkl0ZW1zLmxlbmd0aCA9PT0gYWxsQ2xpcHMubGVuZ3RoICYmIHByZXZJdGVt
cy5sZW5ndGgpIHsKICAgICAgICAgICAgc2FtZVBhaW50ID0gdHJ1ZTsKICAgICAgICAgICAgZm9yIChs
ZXQgaSA9IDA7IGkgPCBhbGxDbGlwcy5sZW5ndGg7IGkrKykgewogICAgICAgICAgICAgICAgaWYgKCtw
cmV2SXRlbXNbaV0uaWQgIT09ICthbGxDbGlwc1tpXS5pZCkgeyBzYW1lUGFpbnQgPSBmYWxzZTsgYnJl
YWs7IH0KICAgICAgICAgICAgfQogICAgICAgICAgICBpZiAoc2FtZVBhaW50ICYmICFsaXN0RWwucXVl
cnlTZWxlY3RvcignLml0bScpKSBzYW1lUGFpbnQgPSBmYWxzZTsKICAgICAgICB9CiAgICAgICAgY29u
c3QgZmluaXNoVXBkYXRlID0gKCkgPT4gewogICAgICAgICAgICBzZXRCb290TG9hZGluZyhmYWxzZSk7
CiAgICAgICAgICAgIGlmICghc2FtZVBhaW50KSB7CiAgICAgICAgICAgICAgICByZW5kZXIoKTsKICAg
ICAgICAgICAgICAgIGFwcGx5VGFiU3dpdGNoQW5pbSgpOwogICAgICAgICAgICB9CiAgICAgICAgICAg
IGlmIChrZWVwU2Nyb2xsKQogICAgICAgICAgICAgICAgbGlzdEVsLnNjcm9sbFRvcCA9IHN0OwogICAg
ICAgICAgICBlbHNlIGlmICghc2FtZVBhaW50KQogICAgICAgICAgICAgICAgbGlzdEVsLnNjcm9sbFRv
cCA9IDA7CiAgICAgICAgfTsKICAgICAgICBpZiAod2FzQm9vdExvYWRpbmcpIHsKICAgICAgICAgICAg
Y29uc3Qgc2luY2UgPSB3aW5kb3cuX19za2VsU2luY2UgfHwgMDsKICAgICAgICAgICAgY29uc3Qgd2Fp
dCA9IHNpbmNlID8gTWF0aC5tYXgoMCwgODAgLSAoRGF0ZS5ub3coKSAtIHNpbmNlKSkgOiAwOwogICAg
ICAgICAgICBpZiAod2FpdCA+IDApCiAgICAgICAgICAgICAgICBzZXRUaW1lb3V0KGZpbmlzaFVwZGF0
ZSwgd2FpdCk7CiAgICAgICAgICAgIGVsc2UKICAgICAgICAgICAgICAgIGZpbmlzaFVwZGF0ZSgpOwog
ICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgIGZpbmlzaFVwZGF0ZSgpOwogICAgICAgIH0KICAgIH07
CiAgICB3aW5kb3cuX19zZXRQaW5uZWQgPSB2ID0+IHsKICAgICAgICBwaW5uZWRVSSA9ICEhdjsKICAg
ICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLXBpbicpLmNsYXNzTGlzdC50b2dnbGUoJ29u
JywgcGlubmVkVUkpOwogICAgfTsKICAgIHdpbmRvdy5fX2xvYWRNb3JlRG9uZSA9ICgpID0+IHsKICAg
ICAgICBsb2FkaW5nTW9yZSA9IGZhbHNlOwogICAgfTsKCiAgICByZXF1ZXN0VmlldygpOwogICAgcmVu
ZGVyKCk7CgogICAgPC9zY3JpcHQ+CjwvYm9keT4KPC9odG1sPg==
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
    if !hasCaretPos && !IsOneNoteApp() {
        GetCaretScreenPos(&cx, &cy, &found)
        if found {
            lastCaretX := cx
            lastCaretY := cy
            hasCaretPos := true
        }
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

; Positioning strategy:
; - Light path: GuiThreadInfo / cache / IME
; - Heavy path: MSAA/UIA (other apps only)
; - OneNote: NEVER any caret probe —even Gui/IME can Critical Error; bottom-right only
; If none found →bottom-right
global cachedCaretX := 0
global cachedCaretY := 0
global cachedCaretTick := 0
global pendingCaretHwnd := 0

GetCaretScreenPos(&cx, &cy, &found := false) {
    cx := 0, cy := 0, found := false
    left := 0, top := 0, right := 0, bottom := 0

    ; Hard skip for OneNote —do not touch its process with caret APIs
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
    global wvCore, clips, viewTotal, viewQuery
    if !IsObject(wvCore)
        return
    q := String(viewQuery)
    filtered := Trim(q) != ""
    payload := "{"
    payload .= '"append":' (append ? "true" : "false") ","
    payload .= '"total":' Integer(viewTotal) ","
    payload .= '"query":' JsonStr(q) ","
    payload .= '"filtered":' (filtered ? "true" : "false") ","
    payload .= '"items":' ClipsToJson(append)
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
    global prevActiveWin, clipIgnore
    item := ResolveClip(uid)
    if !IsObject(item)
        return

    eraseN := QQTypedEraseCount()
    ; Hide first  — never keep UI up while disk/JSON work runs
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
        QQEraseTypedInEditor(eraseN)
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
        eraseN := QQTypedEraseCount()
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
            QQEraseTypedInEditor(eraseN)
            TriggerPasteKey()
        } finally {
            SetTimer(() => (clipIgnore := false), -500)
        }
        return
    }

    eraseN := QQTypedEraseCount()
    HidePanel()
    clipIgnore := true
    pastedIds := []
    try {
        if prevActiveWin {
            DllCall("SetForegroundWindow", "Ptr", prevActiveWin)
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
        hay := ""
        if type != "image"
            hay := StrLower(String(c.preview || "") " " String(c.data || "") " "
                . String(c.HasProp("linkTitle") ? c.linkTitle : "") " " favTitle)
        favLower := StrLower(favTitle)
        for part in StrSplit(q, "|") {
            term := Trim(part)
            if term = ""
                continue
            tLower := StrLower(term)
            if type = "image" {
                if favTitle = "" || !InStr(favLower, tLower)
                    return false
            } else if !InStr(hay, tLower) {
                return false
            }
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
        , qqSearchOn, qqQuery, qqAwaitKeyword, viewSwitchGuardUntil
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
    viewTab := newTab
    viewQuery := newQuery
    viewToday := newToday
    lastAppendCount := 0
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
            clips := []
            for c in entry.items
                clips.Push(c)
            viewTotal := entry.total
            MergeLiveFrontIntoClips()
            ClipLog("SetView cache hit tab=" viewTab " n=" clips.Length " total=" viewTotal)
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
    clips := page.items
    viewTotal := page.total
    MergeLiveFrontIntoClips()
    ClipLog("SetView disk tab=" viewTab " n=" clips.Length " total=" viewTotal)
    CacheCurrentView()
    if IsObject(wvCore)
        PushClips(false)
    if qqSearchOn
        QQPushQuery()
    QQSyncPanelVisibility()
    viewSwitchGuardUntil := A_TickCount + 400
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
