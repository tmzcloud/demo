#Requires AutoHotkey v2.0
#NoTrayIcon
#Include %A_Temp%\WebView2.ahk
#SingleInstance Force
#UseHook
Persistent

; ─────────────────────────────────────────────
;  GetCaretPosEx (inlined — GuiThreadInfo / MSAA / UIA / optional hook)
; ─────────────────────────────────────────────
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
    ; preferUIA is unused for OneNote now — callers skipHeavy instead (UIA crashes OneNote)
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
            ; Only Character unit — Line expand was too aggressive on scroll.
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
            ; SMTO_ABORTIFHUNG — don't freeze if target ignores WM_IME_COMPOSITION
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

; ─────────────────────────────────────────────
;  Config
; ─────────────────────────────────────────────
; UI / disk page size: each NDJSON shard holds at most this many records
PAGE_SIZE    := 50
; First paint / load-more chunk shown in the panel (per tab)
VIEW_PAGE_SIZE := 20
CLIP_V1_DIR  := A_ScriptDir "\ahk\clip_v1"
HTML_FILE    := CLIP_V1_DIR "\index.html"
SAVE_FILE    := CLIP_V1_DIR "\clips.json"          ; legacy (migrated once)
PAGES_DIR    := CLIP_V1_DIR "\clips_pages"
MANIFEST_FILE := PAGES_DIR "\manifest.json"
STORE_DIR    := CLIP_V1_DIR "\clips_store"
PAYLOAD_DIR  := CLIP_V1_DIR "\clips_payloads"
PAYLOAD_INLINE_MAX := 4000   ; larger text/link bodies go to external files
STORE_HOST   := "clips.store"
WIN_W_BASE   := 360
WIN_H_BASE   := 520

; ─────────────────────────────────────────────
;  内嵌 HTML（backtick 已转义为 ``）
; ─────────────────────────────────────────────
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
YWc7CiAgICAgICAgICAgIHBvc2l0aW9uOiByZWxhdGl2ZTsKICAgICAgICB9CgogICAgICAgIC8q
IOKUgOKUgCBSb3cgMSDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIAgKi8KICAgICAgICAjaGRyIHsKICAgICAgICAgICAgZGlzcGxheTog
ZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZmxleC1zaHJpbms6IDA7CiAgICAgICAgICAgIHBh
ZGRpbmc6IDVweCA2cHggNXB4IDhweDsgZ2FwOiA0cHg7CiAgICAgICAgICAgIGJhY2tncm91bmQ6
ICNmNGY2ZmI7CiAgICAgICAgfQogICAgICAgICNoZWFydCB7IGZsZXgtc2hyaW5rOiAwOyBsaW5l
LWhlaWdodDogMTsgZGlzcGxheTpmbGV4OyBhbGlnbi1pdGVtczpjZW50ZXI7IH0KICAgICAgICAj
aGVhcnQgc3ZnIHsgd2lkdGg6MTdweDsgaGVpZ2h0OjE3cHg7IGNvbG9yOiB2YXIoLS10eHQyKTsg
fQogICAgICAgICNoZHItZ3JvdyB7IGZsZXg6IDE7IG1pbi13aWR0aDogOHB4OyB9CgogICAgICAg
IC8qIFNlYXJjaDogb3ZlcmxheSBleHBhbmQgKHRyYW5zZm9ybS9vcGFjaXR5IG9ubHkg4oCUIG5v
IHdpZHRoIGxheW91dCB0aHJhc2gpICovCiAgICAgICAgI3NlYXJjaC13cmFwIHsKICAgICAgICAg
ICAgZmxleDogMCAwIDI4cHg7CiAgICAgICAgICAgIHdpZHRoOiAyOHB4OwogICAgICAgICAgICBo
ZWlnaHQ6IDI4cHg7CiAgICAgICAgICAgIHBvc2l0aW9uOiByZWxhdGl2ZTsKICAgICAgICAgICAg
ei1pbmRleDogNjsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAt
cmVnaW9uOiBuby1kcmFnOwogICAgICAgIH0KICAgICAgICAjYnRuLXNlYXJjaCB7CiAgICAgICAg
ICAgIHBvc2l0aW9uOiBhYnNvbHV0ZTsgcmlnaHQ6IDA7IHRvcDogMDsKICAgICAgICAgICAgd2lk
dGg6IDI4cHg7IGhlaWdodDogMjhweDsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgYWxpZ24t
aXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7CiAgICAgICAgICAgIGJvcmRl
cjogbm9uZTsgYmFja2dyb3VuZDogbm9uZTsgY3Vyc29yOiBwb2ludGVyOwogICAgICAgICAgICBj
b2xvcjogdmFyKC0tdHh0Myk7IGJvcmRlci1yYWRpdXM6IHZhcigtLXIpOwogICAgICAgICAgICB6
LWluZGV4OiAyOwogICAgICAgICAgICB0cmFuc2l0aW9uOiBjb2xvciAwLjE1cyBlYXNlLCBiYWNr
Z3JvdW5kIDAuMTVzIGVhc2UsIG9wYWNpdHkgMC4xNXMgZWFzZTsKICAgICAgICB9CiAgICAgICAg
I2J0bi1zZWFyY2g6aG92ZXIgeyBjb2xvcjogdmFyKC0tYWNjKTsgYmFja2dyb3VuZDogcmdiYSg5
MSwxMTUsMjMyLC4xKTsgfQogICAgICAgICNidG4tc2VhcmNoIHN2ZyB7IHdpZHRoOiAxNXB4OyBo
ZWlnaHQ6IDE1cHg7IGRpc3BsYXk6IGJsb2NrOyB9CiAgICAgICAgI3NlYXJjaC13cmFwLm9wZW4g
I2J0bi1zZWFyY2ggewogICAgICAgICAgICBvcGFjaXR5OiAwOwogICAgICAgICAgICBwb2ludGVy
LWV2ZW50czogbm9uZTsKICAgICAgICB9CgogICAgICAgICNzZWFyY2gtYm94IHsKICAgICAgICAg
ICAgcG9zaXRpb246IGFic29sdXRlOwogICAgICAgICAgICByaWdodDogMDsKICAgICAgICAgICAg
dG9wOiAwOwogICAgICAgICAgICB3aWR0aDogMTY4cHg7CiAgICAgICAgICAgIGhlaWdodDogMjhw
eDsKICAgICAgICAgICAgYm94LXNpemluZzogYm9yZGVyLWJveDsKICAgICAgICAgICAgcGFkZGlu
ZzogMCAycHg7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNmNGY2ZmI7CiAgICAgICAgICAgIGJv
cmRlci1yYWRpdXM6IHZhcigtLXIpOwogICAgICAgICAgICBvcGFjaXR5OiAwOwogICAgICAgICAg
ICB0cmFuc2Zvcm06IHRyYW5zbGF0ZTNkKDhweCwgMCwgMCk7CiAgICAgICAgICAgIHBvaW50ZXIt
ZXZlbnRzOiBub25lOwogICAgICAgICAgICB3aWxsLWNoYW5nZTogdHJhbnNmb3JtLCBvcGFjaXR5
OwogICAgICAgICAgICBiYWNrZmFjZS12aXNpYmlsaXR5OiBoaWRkZW47CiAgICAgICAgICAgIHRy
YW5zaXRpb246IG9wYWNpdHkgMC4xNnMgZWFzZSwgdHJhbnNmb3JtIDAuMnMgY3ViaWMtYmV6aWVy
KDAuMjIsIDEsIDAuMzYsIDEpOwogICAgICAgIH0KICAgICAgICAjc2VhcmNoLXdyYXAub3BlbiAj
c2VhcmNoLWJveCB7CiAgICAgICAgICAgIG9wYWNpdHk6IDE7CiAgICAgICAgICAgIHRyYW5zZm9y
bTogdHJhbnNsYXRlM2QoMCwgMCwgMCk7CiAgICAgICAgICAgIHBvaW50ZXItZXZlbnRzOiBhdXRv
OwogICAgICAgIH0KCiAgICAgICAgI3NlYXJjaCB7CiAgICAgICAgICAgIHdpZHRoOiAxMDAlOyBo
ZWlnaHQ6IDI4cHg7IGJvcmRlcjogbm9uZTsKICAgICAgICAgICAgYm9yZGVyLWJvdHRvbTogMXB4
IHNvbGlkIHRyYW5zcGFyZW50OwogICAgICAgICAgICBib3JkZXItcmFkaXVzOiAwOyBiYWNrZ3Jv
dW5kOiB0cmFuc3BhcmVudDsgY29sb3I6IHZhcigtLXR4dCk7IGZvbnQtc2l6ZTogMTJweDsKICAg
ICAgICAgICAgcGFkZGluZzogMCAyNnB4IDAgNHB4OyBvdXRsaW5lOiBub25lOwogICAgICAgICAg
ICB0cmFuc2l0aW9uOiBib3JkZXItYm90dG9tLWNvbG9yIDAuMTVzIGVhc2U7CiAgICAgICAgfQog
ICAgICAgICNzZWFyY2gtd3JhcC5vcGVuICNzZWFyY2g6Zm9jdXMgewogICAgICAgICAgICBib3Jk
ZXItYm90dG9tLWNvbG9yOiB2YXIoLS1hY2MpOwogICAgICAgIH0KICAgICAgICAjc2VhcmNoLXdy
YXAub3BlbiAjc2VhcmNoLmhhcy12YWw6bm90KDpmb2N1cykgewogICAgICAgICAgICBib3JkZXIt
Ym90dG9tLWNvbG9yOiAjYzVjYWQ2OwogICAgICAgIH0KICAgICAgICAjc2VhcmNoOjpwbGFjZWhv
bGRlciB7IGNvbG9yOiB2YXIoLS10eHQzKTsgfQogICAgICAgICNzZWFyY2gtY2xyIHsKICAgICAg
ICAgICAgcG9zaXRpb246IGFic29sdXRlOyByaWdodDogNHB4OyB0b3A6IDUwJTsgdHJhbnNmb3Jt
OiB0cmFuc2xhdGVZKC01MCUpOwogICAgICAgICAgICBib3JkZXI6IG5vbmU7IGJhY2tncm91bmQ6
IG5vbmU7IGNvbG9yOiB2YXIoLS10eHQzKTsgY3Vyc29yOiBwb2ludGVyOwogICAgICAgICAgICBm
b250LXNpemU6IDExcHg7IGRpc3BsYXk6IG5vbmU7IHBhZGRpbmc6IDJweDsKICAgICAgICAgICAg
b3BhY2l0eTogMC44NTsKICAgICAgICAgICAgdHJhbnNpdGlvbjogY29sb3IgMC4xMnMgZWFzZSwg
b3BhY2l0eSAwLjEycyBlYXNlOwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRy
YWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgfQogICAgICAgICNzZWFyY2gtY2xyOmhv
dmVyIHsgY29sb3I6IHZhcigtLWFjYyk7IG9wYWNpdHk6IDE7IH0KCiAgICAgICAgI2J0bi1waW4g
ewogICAgICAgICAgICB3aWR0aDogMjhweDsgaGVpZ2h0OiAyOHB4OyBmbGV4LXNocmluazogMDsK
ICAgICAgICAgICAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1j
b250ZW50OiBjZW50ZXI7CiAgICAgICAgICAgIGJvcmRlcjogMS41cHggc29saWQgdHJhbnNwYXJl
bnQ7IGJhY2tncm91bmQ6IG5vbmU7IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICAgICAgY29sb3I6
IHZhcigtLXR4dDMpOyBib3JkZXItcmFkaXVzOiB2YXIoLS1yKTsKICAgICAgICAgICAgLXdlYmtp
dC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgICAgICB0
cmFuc2l0aW9uOiBjb2xvciB2YXIoLS10ciksIGJhY2tncm91bmQgdmFyKC0tdHIpLCBib3JkZXIt
Y29sb3IgdmFyKC0tdHIpOwogICAgICAgIH0KICAgICAgICAjYnRuLXBpbjpob3ZlciB7IGNvbG9y
OiB2YXIoLS1hY2MpOyBiYWNrZ3JvdW5kOiByZ2JhKDkxLDExNSwyMzIsLjEpOyB9CiAgICAgICAg
I2J0bi1waW4ub24gIHsKICAgICAgICAgICAgY29sb3I6IHZhcigtLWFjYyk7CiAgICAgICAgICAg
IGJhY2tncm91bmQ6IHJnYmEoOTEsMTE1LDIzMiwuMTgpOwogICAgICAgICAgICBib3JkZXItY29s
b3I6IHJnYmEoOTEsMTE1LDIzMiwuNTUpOwogICAgICAgIH0KICAgICAgICAjYnRuLXBpbiBzdmcg
eyB3aWR0aDogMTRweDsgaGVpZ2h0OiAxNHB4OyBkaXNwbGF5OiBibG9jazsgfQoKICAgICAgICAv
KiDilIDilIAgUm93IDIg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSAICovCiAgICAgICAgI3RhYnMgewogICAgICAgICAgICBkaXNwbGF5
OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDJweDsgZmxleC13cmFwOiB3cmFwOwog
ICAgICAgICAgICBwYWRkaW5nOiA1cHggNnB4IDVweCA4cHg7IGZsZXgtc2hyaW5rOiAwOwogICAg
ICAgICAgICBiYWNrZ3JvdW5kOiAjZjJmNGY5OwogICAgICAgIH0KICAgICAgICAudGFiIHsKICAg
ICAgICAgICAgcGFkZGluZzogM3B4IDdweDsgZm9udC1zaXplOiAxMXB4OyBjb2xvcjogdmFyKC0t
dHh0Mik7IGN1cnNvcjogcG9pbnRlcjsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogdmFyKC0t
cik7IHdoaXRlLXNwYWNlOiBub3dyYXA7CiAgICAgICAgICAgIC13ZWJraXQtYXBwLXJlZ2lvbjog
bm8tZHJhZzsgYXBwLXJlZ2lvbjogbm8tZHJhZzsKICAgICAgICB9CiAgICAgICAgLnRhYjpob3Zl
ciB7IGNvbG9yOiB2YXIoLS10eHQpOyBiYWNrZ3JvdW5kOiByZ2JhKDI1NSwyNTUsMjU1LC43KTsg
fQogICAgICAgIC50YWIub24geyBjb2xvcjogdmFyKC0tYWNjKTsgYmFja2dyb3VuZDogI2ZmZjsg
Ym94LXNoYWRvdzogMCAxcHggMnB4IHJnYmEoMCwwLDAsLjA2KTsgZm9udC13ZWlnaHQ6IDYwMDsg
fQogICAgICAgIC5iYWRnZSB7CiAgICAgICAgICAgIGRpc3BsYXk6IGlubGluZS1mbGV4OyBtaW4t
d2lkdGg6IDE0cHg7IGhlaWdodDogMTRweDsgcGFkZGluZzogMCAzcHg7CiAgICAgICAgICAgIGFs
aWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwogICAgICAgICAgICBi
YWNrZ3JvdW5kOiB2YXIoLS1hY2MpOyBjb2xvcjogI2ZmZjsgZm9udC1zaXplOiA5cHg7IGJvcmRl
ci1yYWRpdXM6IDdweDsgZm9udC13ZWlnaHQ6IDcwMDsKICAgICAgICB9CiAgICAgICAgI3RhYi1h
Y3Rpb25zIHsKICAgICAgICAgICAgbWFyZ2luLWxlZnQ6IGF1dG87IGRpc3BsYXk6IGZsZXg7IGFs
aWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogNHB4OwogICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0
Myk7IGZvbnQtc2l6ZTogMTBweDsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1k
cmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgIH0KICAgICAgICAjYmFyLXR4dCB7IHdo
aXRlLXNwYWNlOiBub3dyYXA7IH0KICAgICAgICAjYnRuLWNsciB7CiAgICAgICAgICAgIGRpc3Bs
YXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwog
ICAgICAgICAgICB3aWR0aDogMjZweDsgaGVpZ2h0OiAyNnB4OyBib3JkZXI6IG5vbmU7IGJhY2tn
cm91bmQ6IG5vbmU7IGNvbG9yOiB2YXIoLS10eHQzKTsKICAgICAgICAgICAgY3Vyc29yOiBwb2lu
dGVyOyBib3JkZXItcmFkaXVzOiB2YXIoLS1yKTsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVn
aW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgICAgICB0cmFuc2l0aW9u
OiBjb2xvciB2YXIoLS10ciksIGJhY2tncm91bmQgdmFyKC0tdHIpOwogICAgICAgIH0KICAgICAg
ICAjYnRuLWNscjpob3ZlciB7IGNvbG9yOiAjZmY3YjljOyBiYWNrZ3JvdW5kOiByZ2JhKDI1NSwx
MjMsMTU2LC4wOCk7IH0KICAgICAgICAjYnRuLWNsciBzdmcgeyB3aWR0aDogMTRweDsgaGVpZ2h0
OiAxNHB4OyBkaXNwbGF5OiBibG9jazsgfQoKICAgICAgICAvKiDilIDilIAgTGlzdCDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAg
Ki8KICAgICAgICAjbGlzdCB7CiAgICAgICAgICAgIGZsZXg6IDE7IG92ZXJmbG93LXk6IGF1dG87
IHBhZGRpbmc6IDZweDsgY3Vyc29yOiBkZWZhdWx0OwogICAgICAgICAgICAtd2Via2l0LWFwcC1y
ZWdpb246IGRyYWc7IGFwcC1yZWdpb246IGRyYWc7CiAgICAgICAgICAgIG1pbi1oZWlnaHQ6IDA7
CiAgICAgICAgfQogICAgICAgICNidG4tdG9wIHsKICAgICAgICAgICAgcG9zaXRpb246IGFic29s
dXRlOyByaWdodDogMTBweDsgYm90dG9tOiAxMHB4OyB6LWluZGV4OiAyMDsKICAgICAgICAgICAg
d2lkdGg6IDI4cHg7IGhlaWdodDogMjhweDsgYm9yZGVyOiBub25lOyBib3JkZXItcmFkaXVzOiA1
MCU7CiAgICAgICAgICAgIGRpc3BsYXk6IG5vbmU7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3Rp
ZnktY29udGVudDogY2VudGVyOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZmZmOyBjb2xvcjog
dmFyKC0tdHh0Mik7CiAgICAgICAgICAgIGJveC1zaGFkb3c6IDAgMnB4IDhweCByZ2JhKDI0LDMy
LDU2LC4xNik7CiAgICAgICAgICAgIGN1cnNvcjogcG9pbnRlcjsKICAgICAgICAgICAgLXdlYmtp
dC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgICAgICB0
cmFuc2l0aW9uOiBiYWNrZ3JvdW5kIHZhcigtLXRyKSwgY29sb3IgdmFyKC0tdHIpLCBib3gtc2hh
ZG93IHZhcigtLXRyKTsKICAgICAgICB9CiAgICAgICAgI2J0bi10b3Aub24geyBkaXNwbGF5OiBm
bGV4OyB9CiAgICAgICAgI2J0bi10b3A6aG92ZXIgeyBjb2xvcjogdmFyKC0tYWNjKTsgYmFja2dy
b3VuZDogI2VkZjFmZjsgYm94LXNoYWRvdzogMCAzcHggMTBweCByZ2JhKDkxLDExNSwyMzIsLjI1
KTsgfQogICAgICAgICNidG4tdG9wIHN2ZyB7IHdpZHRoOiAxNHB4OyBoZWlnaHQ6IDE0cHg7IGRp
c3BsYXk6IGJsb2NrOyB9CiAgICAgICAgI2VtcHR5IHsKICAgICAgICAgICAgZGlzcGxheTogbm9u
ZTsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1j
b250ZW50OiBjZW50ZXI7CiAgICAgICAgICAgIHBhZGRpbmc6IDQwcHggMTZweDsgY29sb3I6IHZh
cigtLXR4dDMpOyBnYXA6IDhweDsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBkcmFn
OyBhcHAtcmVnaW9uOiBkcmFnOwogICAgICAgIH0KICAgICAgICAjZW1wdHkub24geyBkaXNwbGF5
OiBmbGV4OyB9CiAgICAgICAgLmUtaWNvIHsKICAgICAgICAgICAgd2lkdGg6IDQ4cHg7IGhlaWdo
dDogNDhweDsgb3BhY2l0eTogLjk7CiAgICAgICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0
ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwogICAgICAgIH0KICAgICAgICAu
ZS1pY28gc3ZnIHsgd2lkdGg6IDQ4cHg7IGhlaWdodDogNDhweDsgZGlzcGxheTogYmxvY2s7IH0K
ICAgICAgICAuZS10eHQgeyBmb250LXNpemU6IDExcHg7IHRleHQtYWxpZ246IGNlbnRlcjsgfQoK
ICAgICAgICAuaXRtIHsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGZs
ZXgtc3RhcnQ7IGdhcDogOHB4OwogICAgICAgICAgICBwYWRkaW5nOiA4cHg7IG1hcmdpbi1ib3R0
b206IDVweDsKICAgICAgICAgICAgYmFja2dyb3VuZDogdmFyKC0tY2FyZCk7IGJvcmRlci1yYWRp
dXM6IHZhcigtLXIpOyBjdXJzb3I6IHBvaW50ZXI7CiAgICAgICAgICAgIGJveC1zaGFkb3c6IDAg
MXB4IDNweCByZ2JhKDI0LDMyLDU2LC4wNik7CiAgICAgICAgICAgIHRyYW5zaXRpb246IGJhY2tn
cm91bmQgdmFyKC0tdHIpLCBib3gtc2hhZG93IHZhcigtLXRyKTsKICAgICAgICAgICAgLXdlYmtp
dC1hcHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgIH0KICAg
ICAgICAuaXRtOmhvdmVyIHsgYmFja2dyb3VuZDogdmFyKC0tY2FyZC1oKTsgYm94LXNoYWRvdzog
MCAycHggNnB4IHJnYmEoMjQsMzIsNTYsLjEpOyB9CiAgICAgICAgLml0bS5zZWwgewogICAgICAg
ICAgICBib3gtc2hhZG93OiAwIDAgMCAycHggcmdiYSg5MSwxMTUsMjMyLC40NSksIDAgMnB4IDhw
eCByZ2JhKDkxLDExNSwyMzIsLjE4KTsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2VkZjFmZjsK
ICAgICAgICB9CiAgICAgICAgLml0bS5tdWx0aSB7CiAgICAgICAgICAgIGJveC1zaGFkb3c6IDAg
MCAwIDEuNXB4IHJnYmEoOTEsMTE1LDIzMiwuNTUpLCAwIDJweCA2cHggcmdiYSg5MSwxMTUsMjMy
LC4xOCk7CiAgICAgICAgICAgIGJhY2tncm91bmQ6ICNlZWYyZmY7CiAgICAgICAgfQogICAgICAg
IC5pdG0ubXVsdGkuc2VsIHsKICAgICAgICAgICAgYm94LXNoYWRvdzogMCAwIDAgMnB4IHJnYmEo
OTEsMTE1LDIzMiwuNyksIDAgMnB4IDhweCByZ2JhKDkxLDExNSwyMzIsLjIyKTsKICAgICAgICB9
CgogICAgICAgICNtdWx0aS1jbnQgewogICAgICAgICAgICBkaXNwbGF5OiBub25lOyBhbGlnbi1p
dGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAgICAgICAgICAgaGVpZ2h0
OiAyMnB4OyBwYWRkaW5nOiAwIDhweDsgbWFyZ2luLXJpZ2h0OiA0cHg7CiAgICAgICAgICAgIGJv
cmRlcjogbm9uZTsgYm9yZGVyLXJhZGl1czogMTFweDsgY3Vyc29yOiBwb2ludGVyOwogICAgICAg
ICAgICBiYWNrZ3JvdW5kOiB2YXIoLS1hY2MpOyBjb2xvcjogI2ZmZjsgZm9udC1zaXplOiAxMXB4
OyBmb250LXdlaWdodDogNzAwOwogICAgICAgICAgICAtd2Via2l0LWFwcC1yZWdpb246IG5vLWRy
YWc7IGFwcC1yZWdpb246IG5vLWRyYWc7CiAgICAgICAgICAgIHRyYW5zaXRpb246IG9wYWNpdHkg
dmFyKC0tdHIpLCBiYWNrZ3JvdW5kIHZhcigtLXRyKTsKICAgICAgICB9CiAgICAgICAgI211bHRp
LWNudDpob3ZlciB7IGJhY2tncm91bmQ6ICM0YTYyZDQ7IH0KICAgICAgICAjbXVsdGktY250Lm9u
IHsgZGlzcGxheTogaW5saW5lLWZsZXg7IH0KCiAgICAgICAgLmktaWNvIHsKICAgICAgICAgICAg
d2lkdGg6IDI4cHg7IGhlaWdodDogMjhweDsgYm9yZGVyLXJhZGl1czogdmFyKC0tcik7IGRpc3Bs
YXk6IGZsZXg7CiAgICAgICAgICAgIGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVu
dDogY2VudGVyOyBmbGV4LXNocmluazogMDsKICAgICAgICAgICAgYmFja2dyb3VuZDogI2VkZjJm
ZjsgY29sb3I6IHZhcigtLWFjYyk7CiAgICAgICAgfQogICAgICAgIC5pLWljbyBzdmcgeyB3aWR0
aDogMTZweDsgaGVpZ2h0OiAxNnB4OyBkaXNwbGF5OiBibG9jazsgfQogICAgICAgIC5pLWljby5m
dC1pbWcgeyBjb2xvcjogIzdhZDdmZjsgfQogICAgICAgIC5pLWljby5mdC16aXAgeyBjb2xvcjog
IzhhYjRmZjsgfQogICAgICAgIC5pLWljby5mdC1kaXIgeyBjb2xvcjogI2ZmZDU2YTsgfQogICAg
ICAgIC5pLWljby5mdC1haGsgeyBjb2xvcjogIzZkZmY5YTsgfQogICAgICAgIC5pLWljby5mdC1s
bmssIC5pLWljby5mdC1kb2MgeyBjb2xvcjogI2E5YmRkMDsgfQoKICAgICAgICAuaS1ib2R5IHsg
ZmxleDogMTsgbWluLXdpZHRoOiAwOyBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29s
dW1uOyB9CiAgICAgICAgLmktcHJldiwgLmktbmFtZSB7CiAgICAgICAgICAgIGZvbnQtc2l6ZTog
MTNweDsgZm9udC13ZWlnaHQ6IDUwMDsgY29sb3I6IHZhcigtLXR4dCk7IHdvcmQtYnJlYWs6IGJy
ZWFrLWFsbDsKICAgICAgICAgICAgZGlzcGxheTogLXdlYmtpdC1ib3g7IC13ZWJraXQtYm94LW9y
aWVudDogdmVydGljYWw7IC13ZWJraXQtbGluZS1jbGFtcDogMjsgb3ZlcmZsb3c6IGhpZGRlbjsK
ICAgICAgICAgICAgd2hpdGUtc3BhY2U6IHByZS13cmFwOyAvKiDmlK/mjIHlpJrmlofku7Yv5aSa
6KGM5paH5pys5o2i6KGM5pi+56S6ICovCiAgICAgICAgfQogICAgICAgIC5pLXByZXYudXJsIHsg
Y29sb3I6IHZhcigtLWFjYyk7IH0KICAgICAgICAuaS10aHVtYi13cmFwIHsKICAgICAgICAgICAg
d2lkdGg6IDEwMCU7IG1heC1oZWlnaHQ6IDE4MHB4OyBtYXJnaW4tYm90dG9tOiA0cHg7CiAgICAg
ICAgICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVu
dDogY2VudGVyOwogICAgICAgICAgICBiYWNrZ3JvdW5kOiAjZjNmNWY5OyBib3JkZXItcmFkaXVz
OiB2YXIoLS1yKTsgb3ZlcmZsb3c6IGhpZGRlbjsKICAgICAgICB9CiAgICAgICAgLmktdGh1bWIg
eyBtYXgtd2lkdGg6IDEwMCU7IG1heC1oZWlnaHQ6IDE4MHB4OyB3aWR0aDogYXV0bzsgaGVpZ2h0
OiBhdXRvOyBvYmplY3QtZml0OiBjb250YWluOyBkaXNwbGF5OiBibG9jazsgfQoKICAgICAgICAv
KiBNZXRhIGJhcjogdGltZSBsZWZ0IHwgZXhwYW5kIGNlbnRlciB8IHRhZ3MgcmlnaHQgKi8KICAg
ICAgICAuaS1tZXRhIHsKICAgICAgICAgICAgZGlzcGxheTogZ3JpZDsKICAgICAgICAgICAgZ3Jp
ZC10ZW1wbGF0ZS1jb2x1bW5zOiAxZnIgYXV0byAxZnI7CiAgICAgICAgICAgIGFsaWduLWl0ZW1z
OiBjZW50ZXI7CiAgICAgICAgICAgIGdhcDogNHB4OwogICAgICAgICAgICBtYXJnaW4tdG9wOiA0
cHg7CiAgICAgICAgICAgIHdpZHRoOiAxMDAlOwogICAgICAgIH0KICAgICAgICAuaS1tZXRhIC5p
LXRpbWUgeyBqdXN0aWZ5LXNlbGY6IHN0YXJ0OyB9CiAgICAgICAgLmktbWV0YS1jZW50ZXIgewog
ICAgICAgICAgICBqdXN0aWZ5LXNlbGY6IGNlbnRlcjsKICAgICAgICAgICAgZGlzcGxheTogZmxl
eDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBjZW50ZXI7CiAgICAgICAg
ICAgIG1pbi13aWR0aDogMXB4OyAvKiBrZWVwIGNlbnRlciBjb2x1bW4gZXZlbiB3aGVuIGV4cGFu
ZCBpcyBoaWRkZW4gKi8KICAgICAgICB9CiAgICAgICAgLmktbWV0YS1yaWdodCB7CiAgICAgICAg
ICAgIGp1c3RpZnktc2VsZjogZW5kOwogICAgICAgICAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1p
dGVtczogY2VudGVyOyBnYXA6IDVweDsgZmxleC13cmFwOiB3cmFwOwogICAgICAgICAgICBqdXN0
aWZ5LWNvbnRlbnQ6IGZsZXgtZW5kOwogICAgICAgIH0KICAgICAgICAuaS10aW1lLCAuaS10YWcg
eyBmb250LXNpemU6IDEwcHg7IGNvbG9yOiB2YXIoLS10eHQzKTsgfQogICAgICAgIC5pLXRhZyB7
IGJhY2tncm91bmQ6ICNmMWYzZjg7IHBhZGRpbmc6IDAgNXB4OyBib3JkZXItcmFkaXVzOiAzcHg7
IH0KICAgICAgICAuaS10YWcubWQtYmFkZ2UgeyBiYWNrZ3JvdW5kOiAjZThlZGZmOyBjb2xvcjog
dmFyKC0tYWNjKTsgZm9udC13ZWlnaHQ6IDcwMDsgfQogICAgICAgIC5pLW51bSB7IGZvbnQtc2l6
ZTogMTBweDsgY29sb3I6IHZhcigtLXR4dDMpOyBtaW4td2lkdGg6IDE0cHg7IHRleHQtYWxpZ246
IHJpZ2h0OyBtYXJnaW4tdG9wOiA0cHg7IH0KCiAgICAgICAgLmktZXhwYW5kLWJ0biB7CiAgICAg
ICAgICAgIGJvcmRlcjogbm9uZTsgYmFja2dyb3VuZDogbm9uZTsgY3Vyc29yOiBwb2ludGVyOwog
ICAgICAgICAgICBjb2xvcjogdmFyKC0tdHh0Myk7IGZvbnQtc2l6ZTogMTBweDsgcGFkZGluZzog
MXB4IDZweDsKICAgICAgICAgICAgYm9yZGVyLXJhZGl1czogOHB4OyBkaXNwbGF5OiBub25lOyBh
bGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDJweDsKICAgICAgICAgICAgdHJhbnNpdGlvbjogY29s
b3IgdmFyKC0tdHIpLCBiYWNrZ3JvdW5kIHZhcigtLXRyKTsKICAgICAgICAgICAgLXdlYmtpdC1h
cHAtcmVnaW9uOiBuby1kcmFnOyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgIH0KICAgICAg
ICAuaS1leHBhbmQtYnRuLm9uIHsgZGlzcGxheTogaW5saW5lLWZsZXg7IH0KICAgICAgICAuaS1l
eHBhbmQtYnRuOmhvdmVyIHsgY29sb3I6IHZhcigtLWFjYyk7IGJhY2tncm91bmQ6IHJnYmEoOTEs
MTE1LDIzMiwuMDgpOyB9CiAgICAgICAgLmktcHJldi5leHBhbmRlZCwgLmktbmFtZS5leHBhbmRl
ZCB7CiAgICAgICAgICAgIC13ZWJraXQtbGluZS1jbGFtcDogdW5zZXQ7CiAgICAgICAgICAgIG92
ZXJmbG93OiB2aXNpYmxlOwogICAgICAgIH0KCiAgICAgICAgLyog4pSA4pSAIENvbnRleHQgbWVu
dSDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAgKi8KICAgICAgICAjY3R4
IHsKICAgICAgICAgICAgcG9zaXRpb246IGZpeGVkOyB6LWluZGV4OiA5OTk5OyBtaW4td2lkdGg6
IDEzMnB4OyBkaXNwbGF5OiBub25lOyBwYWRkaW5nOiA0cHg7CiAgICAgICAgICAgIGJhY2tncm91
bmQ6ICNmZmY7IGJvcmRlci1yYWRpdXM6IHZhcigtLXIpOyBib3gtc2hhZG93OiAwIDZweCAxNnB4
IHJnYmEoMCwwLDAsLjE0KTsKICAgICAgICAgICAgLXdlYmtpdC1hcHAtcmVnaW9uOiBuby1kcmFn
OyBhcHAtcmVnaW9uOiBuby1kcmFnOwogICAgICAgIH0KICAgICAgICAjY3R4Lm9uIHsgZGlzcGxh
eTogYmxvY2s7IH0KICAgICAgICAuYy1pdGVtIHsKICAgICAgICAgICAgZGlzcGxheTogZmxleDsg
YWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiA3cHg7IHBhZGRpbmc6IDZweCA5cHg7CiAgICAgICAg
ICAgIGJvcmRlci1yYWRpdXM6IHZhcigtLXIpOyBjdXJzb3I6IHBvaW50ZXI7IGZvbnQtc2l6ZTog
MTFweDsgY29sb3I6IHZhcigtLXR4dCk7CiAgICAgICAgfQogICAgICAgIC5jLWl0ZW06aG92ZXIg
eyBiYWNrZ3JvdW5kOiAjZjJmNGY5OyB9CiAgICAgICAgLmMtaXRlbS5kYW5nZXIgeyBjb2xvcjog
I2ZmN2I5YzsgfQogICAgICAgIC5jLXNlcCB7IGhlaWdodDogMXB4OyBiYWNrZ3JvdW5kOiAjZWNl
ZmY1OyBtYXJnaW46IDNweCAwOyB9CiAgICAgICAgLmMtaWNvIHsgd2lkdGg6IDE0cHg7IHRleHQt
YWxpZ246IGNlbnRlcjsgfQogICAgPC9zdHlsZT4KPC9oZWFkPgo8Ym9keT4KPGRpdiBpZD0iYXBw
Ij4KICAgIDxkaXYgaWQ9ImhkciI+CiAgICAgICAgPGRpdiBpZD0iaGVhcnQiPgogICAgICAgICAg
ICA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29s
b3IiIHN0cm9rZS13aWR0aD0iMS44IgogICAgICAgICAgICAgICAgIHN0cm9rZS1saW5lY2FwPSJy
b3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI+CiAgICAgICAgICAgICAgICA8cmVjdCB4PSI5
IiB5PSIyIiB3aWR0aD0iNiIgaGVpZ2h0PSI0IiByeD0iMSIvPgogICAgICAgICAgICAgICAgPHBh
dGggZD0iTTE2IDRoMmEyIDIgMCAwIDEgMiAydjE0YTIgMiAwIDAgMS0yIDJINmEyIDIgMCAwIDEt
Mi0yVjZhMiAyIDAgMCAxIDItMmgyIi8+CiAgICAgICAgICAgICAgICA8cGF0aCBkPSJNOSAxMmg2
TTkgMTZoNCIvPgogICAgICAgICAgICA8L3N2Zz4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2
IGlkPSJoZHItZ3JvdyI+PC9kaXY+CiAgICAgICAgPGRpdiBpZD0ic2VhcmNoLXdyYXAiPgogICAg
ICAgICAgICA8YnV0dG9uIGlkPSJidG4tc2VhcmNoIiB0eXBlPSJidXR0b24iIHRpdGxlPSLmkJzn
tKIiPgogICAgICAgICAgICAgICAgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUi
IHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIiCiAgICAgICAgICAgICAgICAg
ICAgIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI+CiAgICAg
ICAgICAgICAgICAgICAgPGNpcmNsZSBjeD0iMTEiIGN5PSIxMSIgcj0iNyIvPgogICAgICAgICAg
ICAgICAgICAgIDxwYXRoIGQ9Ik0yMCAyMGwtMy41LTMuNSIvPgogICAgICAgICAgICAgICAgPC9z
dmc+CiAgICAgICAgICAgIDwvYnV0dG9uPgogICAgICAgICAgICA8ZGl2IGlkPSJzZWFyY2gtYm94
Ij4KICAgICAgICAgICAgICAgIDxpbnB1dCBpZD0ic2VhcmNoIiB0eXBlPSJ0ZXh0IiBwbGFjZWhv
bGRlcj0i5pCc57SiLi4uIiBhdXRvY29tcGxldGU9Im9mZiIgc3BlbGxjaGVjaz0iZmFsc2UiPgog
ICAgICAgICAgICAgICAgPGJ1dHRvbiBpZD0ic2VhcmNoLWNsciIgdHlwZT0iYnV0dG9uIj7inJU8
L2J1dHRvbj4KICAgICAgICAgICAgPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGJ1dHRv
biBpZD0iYnRuLXBpbiIgdHlwZT0iYnV0dG9uIiB0aXRsZT0i6ZKJ5Zyo5bGP5bmV5LiKIj4KICAg
ICAgICAgICAgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3Vy
cmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIiCiAgICAgICAgICAgICAgICAgc3Ryb2tlLWxpbmVq
b2luPSJyb3VuZCIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIj4KICAgICAgICAgICAgICAgIDxsaW5l
IHgxPSIxMiIgeTE9IjE3IiB4Mj0iMTIiIHkyPSIyMiIvPgogICAgICAgICAgICAgICAgPHBhdGgg
ZD0iTTUgMTdoMTR2LTEuNzZhMiAyIDAgMCAwLTEuMTEtMS43OWwtMS43OC0uOUEyIDIgMCAwIDEg
MTUgMTAuNzZWNmgxYTIgMiAwIDAgMCAwLTRIOGEyIDIgMCAwIDAgMCA0aDF2NC43NmEyIDIgMCAw
IDEtMS4xMSAxLjc5bC0xLjc4LjlBMiAyIDAgMCAwIDUgMTUuMjRaIi8+CiAgICAgICAgICAgIDwv
c3ZnPgogICAgICAgIDwvYnV0dG9uPgogICAgPC9kaXY+CgogICAgPGRpdiBpZD0idGFicyI+CiAg
ICAgICAgPGRpdiBjbGFzcz0idGFiIG9uIiBkYXRhLXRhYj0iYWxsIj7lhajpg6g8L2Rpdj4KICAg
ICAgICA8ZGl2IGNsYXNzPSJ0YWIiIGRhdGEtdGFiPSJ0ZXh0Ij7mlofmnKw8L2Rpdj4KICAgICAg
ICA8ZGl2IGNsYXNzPSJ0YWIiIGRhdGEtdGFiPSJpbWFnZSI+5Zu+5YOPPC9kaXY+CiAgICAgICAg
PGRpdiBjbGFzcz0idGFiIiBkYXRhLXRhYj0iZmlsZSI+5paH5Lu2PC9kaXY+CiAgICAgICAgPGRp
diBjbGFzcz0idGFiIiBkYXRhLXRhYj0icGlubmVkIj7mlLbol48gPHNwYW4gY2xhc3M9ImJhZGdl
IiBpZD0icGluLWNudCIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+MDwvc3Bhbj48L2Rpdj4KICAgICAg
ICA8ZGl2IGlkPSJ0YWItYWN0aW9ucyI+CiAgICAgICAgICAgIDxidXR0b24gaWQ9Im11bHRpLWNu
dCIgdHlwZT0iYnV0dG9uIiB0aXRsZT0i5Y+W5raI5aSa6YCJIj7lt7LpgIkgMDwvYnV0dG9uPgog
ICAgICAgICAgICA8c3BhbiBpZD0iYmFyLXR4dCI+MDwvc3Bhbj4KICAgICAgICAgICAgPGJ1dHRv
biBpZD0iYnRuLWNsciIgdHlwZT0iYnV0dG9uIiB0aXRsZT0i5riF56m65Y6G5Y+yIj4KICAgICAg
ICAgICAgICAgIDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1
cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyIgogICAgICAgICAgICAgICAgICAgICBzdHJva2Ut
bGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9pbj0icm91bmQiPgogICAgICAgICAgICAgICAg
ICAgIDxwb2x5bGluZSBwb2ludHM9IjMgNiA1IDYgMjEgNiIvPgogICAgICAgICAgICAgICAgICAg
IDxwYXRoIGQ9Ik0xOSA2bC0xIDE0YTIgMiAwIDAgMS0yIDJIOGEyIDIgMCAwIDEtMi0yTDUgNiIv
PgogICAgICAgICAgICAgICAgICAgIDxwYXRoIGQ9Ik0xMCAxMXY2TTE0IDExdjZNOSA2VjRoNnYy
Ii8+CiAgICAgICAgICAgICAgICA8L3N2Zz4KICAgICAgICAgICAgPC9idXR0b24+CiAgICAgICAg
PC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8ZGl2IGlkPSJsaXN0Ij4KICAgICAgICA8ZGl2IGlkPSJl
bXB0eSIgY2xhc3M9Im9uIj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0iZS1pY28iIGFyaWEtaGlk
ZGVuPSJ0cnVlIj4KICAgICAgICAgICAgICAgIDxzdmcgdmlld0JveD0iMCAwIDY0IDY0IiBmaWxs
PSJub25lIj4KICAgICAgICAgICAgICAgICAgICA8cmVjdCB4PSIxNCIgeT0iMTIiIHdpZHRoPSIz
NiIgaGVpZ2h0PSI0NCIgcng9IjgiIGZpbGw9IiM1QjczRTgiIG9wYWNpdHk9Ii4xOCIvPgogICAg
ICAgICAgICAgICAgICAgIDxyZWN0IHg9IjE4IiB5PSIxNiIgd2lkdGg9IjI4IiBoZWlnaHQ9IjM2
IiByeD0iNiIgZmlsbD0iI2ZmZiIgc3Ryb2tlPSIjNUI3M0U4IiBzdHJva2Utd2lkdGg9IjIiLz4K
ICAgICAgICAgICAgICAgICAgICA8cmVjdCB4PSIyNCIgeT0iMTAiIHdpZHRoPSIxNiIgaGVpZ2h0
PSIxMCIgcng9IjMiIGZpbGw9IiM1QjczRTgiLz4KICAgICAgICAgICAgICAgICAgICA8cmVjdCB4
PSIyOCIgeT0iMTIiIHdpZHRoPSI4IiBoZWlnaHQ9IjYiIHJ4PSIyIiBmaWxsPSIjRUVGMUY2Ii8+
CiAgICAgICAgICAgICAgICAgICAgPHBhdGggZD0iTTI2IDMwaDEyTTI2IDM2aDEyTTI2IDQyaDgi
IHN0cm9rZT0iI0I4QzBEOSIgc3Ryb2tlLXdpZHRoPSIyLjIiIHN0cm9rZS1saW5lY2FwPSJyb3Vu
ZCIvPgogICAgICAgICAgICAgICAgICAgIDxjaXJjbGUgY3g9IjQ4IiBjeT0iMjAiIHI9IjMiIGZp
bGw9IiNGRkI0QzgiLz4KICAgICAgICAgICAgICAgICAgICA8Y2lyY2xlIGN4PSIxMiIgY3k9IjI4
IiByPSIyLjIiIGZpbGw9IiNGRkQ1NkEiLz4KICAgICAgICAgICAgICAgIDwvc3ZnPgogICAgICAg
ICAgICA8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0iZS10eHQiIGlkPSJlbXB0eS10eHQi
PuaaguaXoOiusOW9le+8jOWkjeWItuWQjuiHquWKqOWHuueOsDwvZGl2PgogICAgICAgIDwvZGl2
PgogICAgPC9kaXY+CiAgICA8YnV0dG9uIGlkPSJidG4tdG9wIiB0eXBlPSJidXR0b24iIHRpdGxl
PSLlm57liLDpobbpg6giIGFyaWEtbGFiZWw9IuWbnuWIsOmhtumDqCI+CiAgICAgICAgPHN2ZyB2
aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJv
a2Utd2lkdGg9IjIuMiIKICAgICAgICAgICAgIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tl
LWxpbmVqb2luPSJyb3VuZCI+CiAgICAgICAgICAgIDxwYXRoIGQ9Ik0xMiAxOVY1Ii8+CiAgICAg
ICAgICAgIDxwYXRoIGQ9Ik01IDEybDctNyA3IDciLz4KICAgICAgICA8L3N2Zz4KICAgIDwvYnV0
dG9uPgo8L2Rpdj4KCjxkaXYgaWQ9ImN0eCI+CiAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0iIGlkPSJj
LWNvcHkiPjxzcGFuIGNsYXNzPSJjLWljbyI+4o6YPC9zcGFuPuWkjeWItjwvZGl2PgogICAgPGRp
diBjbGFzcz0iYy1pdGVtIiBpZD0iYy1wYXN0ZSI+PHNwYW4gY2xhc3M9ImMtaWNvIj7ij448L3Nw
YW4+57KY6LS0PC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjLWl0ZW0iIGlkPSJjLWZsb2F0Ij48c3Bh
biBjbGFzcz0iYy1pY28iPuKniTwvc3Bhbj7mgqzmta7kuK3ovaw8L2Rpdj4KICAgIDxkaXYgY2xh
c3M9ImMtc2VwIj48L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImMtaXRlbSIgaWQ9ImMtcGluIj48c3Bh
biBjbGFzcz0iYy1pY28iPuKYhTwvc3Bhbj7mlLbol488L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImMt
aXRlbSIgaWQ9ImMtdG9wIj48c3BhbiBjbGFzcz0iYy1pY28iPuKGkTwvc3Bhbj7np7vliLDpobbp
g6g8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImMtc2VwIj48L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImMt
aXRlbSBkYW5nZXIiIGlkPSJjLWRlbCI+PHNwYW4gY2xhc3M9ImMtaWNvIj7inJU8L3NwYW4+5Yig
6ZmkPC9kaXY+CjwvZGl2PgoKPHNjcmlwdD4KICAgIGxldCBhbGxDbGlwcyA9IFtdLCBjdXJUYWIg
PSAnYWxsJywgcXVlcnkgPSAnJywgY3R4Q2xpcCA9IG51bGwsIHNlbGVjdGVkSWQgPSAwLCBwaW5u
ZWRVSSA9IGZhbHNlOwogICAgbGV0IG11bHRpSWRzID0gW107CgogICAgY29uc3QgRU1QVFlfTVNH
ID0gewogICAgICAgIGFsbDogICAgJ+aaguaXoOiusOW9le+8jOWkjeWItuWQjuiHquWKqOWHuueO
sCcsCiAgICAgICAgdGV4dDogICAn5pqC5peg5paH5pysJywKICAgICAgICBpbWFnZTogICfmmoLm
l6Dlm77lg48nLAogICAgICAgIGZpbGU6ICAgJ+aaguaXoOaWh+S7ticsCiAgICAgICAgcGlubmVk
OiAn5pqC5peg5pS26JePJwogICAgfTsKCiAgICBmdW5jdGlvbiBhaGsobWV0aG9kLCAuLi5hcmdz
KSB7CiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgY29uc3QgaG9zdCA9IGNocm9tZS53ZWJ2aWV3
Lmhvc3RPYmplY3RzLnN5bmMuYWhrOwogICAgICAgICAgICBpZiAoaG9zdCAmJiB0eXBlb2YgaG9z
dC5jYWxsID09PSAnZnVuY3Rpb24nKSB7IGhvc3QuY2FsbChtZXRob2QsIC4uLmFyZ3MpOyByZXR1
cm47IH0KICAgICAgICAgICAgaWYgKGhvc3QgJiYgdHlwZW9mIGhvc3RbbWV0aG9kXSA9PT0gJ2Z1
bmN0aW9uJykgeyBob3N0W21ldGhvZF0oaG9zdCwgLi4uYXJncyk7IHJldHVybjsgfQogICAgICAg
ICAgICBpZiAoaG9zdCAmJiBob3N0W21ldGhvZF0pIGhvc3RbbWV0aG9kXSguLi5hcmdzKTsKICAg
ICAgICB9IGNhdGNoIChlKSB7IGNvbnNvbGUud2FybignYWhrLicgKyBtZXRob2QsIGUpOyB9CiAg
ICB9CgogICAgZnVuY3Rpb24gaXNEcmFnRXhjbHVkZSh0KSB7CiAgICAgICAgcmV0dXJuICEhdC5j
bG9zZXN0KCcjc2VhcmNoLXdyYXAsICNidG4tc2VhcmNoLCAjYnRuLXBpbiwgI2J0bi1jbHIsICNt
dWx0aS1jbnQsIC50YWIsIC5pdG0sICN0YWItYWN0aW9ucywgI2N0eCwgYnV0dG9uLCBpbnB1dCwg
YScpOwogICAgfQogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2FwcCcpLmFkZEV2ZW50TGlz
dGVuZXIoJ21vdXNlZG93bicsIGUgPT4gewogICAgICAgIGlmIChlLmJ1dHRvbiAhPT0gMCkgcmV0
dXJuOwogICAgICAgIGlmIChpc0RyYWdFeGNsdWRlKGUudGFyZ2V0KSkgcmV0dXJuOwogICAgICAg
IGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICBhaGsoJ3N0YXJ0RHJhZycpOwogICAgfSwgdHJ1
ZSk7CgogICAgY29uc3QgaXNVcmwgID0gcyA9PiAvXmh0dHBzPzpcL1wvL2kudGVzdCgocyB8fCAn
JykudHJpbSgpKTsKCiAgICBmdW5jdGlvbiBhZ28oZGF0ZVN0cikgewogICAgICAgIHRyeSB7CiAg
ICAgICAgICAgIGNvbnN0IGQgPSBuZXcgRGF0ZShTdHJpbmcoZGF0ZVN0cikucmVwbGFjZSgnICcs
ICdUJykpOwogICAgICAgICAgICBjb25zdCBzID0gKERhdGUubm93KCkgLSBkKSAvIDEwMDAgfCAw
OwogICAgICAgICAgICBpZiAocyA8IDYwKSByZXR1cm4gJ+WImuWImic7CiAgICAgICAgICAgIGlm
IChzIDwgMzYwMCkgcmV0dXJuIChzIC8gNjAgfCAwKSArICcg5YiG6ZKf5YmNJzsKICAgICAgICAg
ICAgaWYgKHMgPCA4NjQwMCkgcmV0dXJuIChzIC8gMzYwMCB8IDApICsgJyDlsI/ml7bliY0nOwog
ICAgICAgICAgICByZXR1cm4gKHMgLyA4NjQwMCB8IDApICsgJyDlpKnliY0nOwogICAgICAgIH0g
Y2F0Y2ggeyByZXR1cm4gZGF0ZVN0cjsgfQogICAgfQoKICAgIGZ1bmN0aW9uIG5vcm1UeXBlKHQp
IHsKICAgICAgICB0ID0gU3RyaW5nKHQgfHwgJycpLnRvTG93ZXJDYXNlKCk7CiAgICAgICAgaWYg
KHQgPT09ICdpbWFnZScgfHwgdCA9PT0gJ2ltZycgfHwgdCA9PT0gJ2JpdG1hcCcpIHJldHVybiAn
aW1hZ2UnOwogICAgICAgIGlmICh0ID09PSAnZmlsZScgIHx8IHQgPT09ICdmaWxlcycpIHJldHVy
biAnZmlsZSc7CiAgICAgICAgcmV0dXJuICd0ZXh0JzsKICAgIH0KICAgIGZ1bmN0aW9uIGlzUGlu
bmVkKGMpIHsKICAgICAgICByZXR1cm4gYy5waW5uZWQgPT09IHRydWUgfHwgYy5waW5uZWQgPT09
IDEgfHwgYy5waW5uZWQgPT09ICd0cnVlJyB8fCBjLnBpbm5lZCA9PT0gJzEnOwogICAgfQoKICAg
IGZ1bmN0aW9uIGlzTWFya2Rvd24odGV4dCkgewogICAgICAgIGlmICghdGV4dCB8fCB0ZXh0Lmxl
bmd0aCA8IDQpIHJldHVybiBmYWxzZTsKICAgICAgICByZXR1cm4gLyg/Ol58XG4pI3sxLDZ9IHxe
Wy0qK10gfFwqXCpbXipcbl0rXCpcKnxfX1teX1xuXStfX3woPzpefFxuKT4gfF5gYGB8YFteYF0r
YHxcWy4rXF1cKC4rXCl8XHwuK1x8LitcfC8udGVzdCh0ZXh0KTsKICAgIH0KCiAgICBmdW5jdGlv
biBmaWx0ZXIoY2xpcHMsIHRhYiwgcSkgewogICAgICAgIGxldCByID0gY2xpcHMubWFwKGMgPT4g
KHsgLi4uYywgdHlwZTogbm9ybVR5cGUoYy50eXBlKSwgcGlubmVkOiBpc1Bpbm5lZChjKSB9KSk7
CiAgICAgICAgaWYgKHRhYiA9PT0gJ3RleHQnKSAgIHIgPSByLmZpbHRlcihjID0+IGMudHlwZSA9
PT0gJ3RleHQnKTsKICAgICAgICBpZiAodGFiID09PSAnaW1hZ2UnKSAgciA9IHIuZmlsdGVyKGMg
PT4gYy50eXBlID09PSAnaW1hZ2UnKTsKICAgICAgICBpZiAodGFiID09PSAnZmlsZScpICAgciA9
IHIuZmlsdGVyKGMgPT4gYy50eXBlID09PSAnZmlsZScpOwogICAgICAgIGlmICh0YWIgPT09ICdw
aW5uZWQnKSByID0gci5maWx0ZXIoYyA9PiBjLnBpbm5lZCk7CiAgICAgICAgaWYgKHEpIHsKICAg
ICAgICAgICAgY29uc3QgbHEgPSBxLnRvTG93ZXJDYXNlKCk7CiAgICAgICAgICAgIHIgPSByLmZp
bHRlcihjID0+IGMudHlwZSAhPT0gJ2ltYWdlJyAmJiBTdHJpbmcoYy5wcmV2aWV3IHx8IGMuZGF0
YSB8fCAnJykudG9Mb3dlckNhc2UoKS5pbmNsdWRlcyhscSkpOwogICAgICAgIH0KICAgICAgICBy
ZXR1cm4gcjsKICAgIH0KCiAgICBjb25zdCBsaXN0RWwgID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ2xpc3QnKTsKICAgIGNvbnN0IGVtcHR5RWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgn
ZW1wdHknKTsKICAgIGNvbnN0IGJ0blRvcCAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRu
LXRvcCcpOwoKICAgIGZ1bmN0aW9uIHVwZGF0ZVRvcEJ0bigpIHsKICAgICAgICBpZiAoIWJ0blRv
cCB8fCAhbGlzdEVsKSByZXR1cm47CiAgICAgICAgYnRuVG9wLmNsYXNzTGlzdC50b2dnbGUoJ29u
JywgbGlzdEVsLnNjcm9sbFRvcCA+IDQ4KTsKICAgIH0KICAgIGxpc3RFbC5hZGRFdmVudExpc3Rl
bmVyKCdzY3JvbGwnLCB1cGRhdGVUb3BCdG4sIHsgcGFzc2l2ZTogdHJ1ZSB9KTsKICAgIGJ0blRv
cC5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGUuc3RvcFByb3BhZ2F0
aW9uKCk7CiAgICAgICAgbGlzdEVsLnNjcm9sbFRvKHsgdG9wOiAwLCBiZWhhdmlvcjogJ3Ntb290
aCcgfSk7CiAgICB9KTsKCiAgICBmdW5jdGlvbiB2aXNpYmxlTGlzdCgpIHsgcmV0dXJuIGZpbHRl
cihhbGxDbGlwcywgY3VyVGFiLCBxdWVyeSk7IH0KCiAgICBmdW5jdGlvbiBzZXRUYWIodGFiKSB7
CiAgICAgICAgY3VyVGFiID0gdGFiOwogICAgICAgIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwo
Jy50YWInKS5mb3JFYWNoKGVsID0+IGVsLmNsYXNzTGlzdC50b2dnbGUoJ29uJywgZWwuZGF0YXNl
dC50YWIgPT09IHRhYikpOwogICAgICAgIHJlbmRlcigpOwogICAgfQoKICAgIGZ1bmN0aW9uIHNl
bGVjdEJ5SW5kZXgoaWR4KSB7CiAgICAgICAgY29uc3QgdmlzID0gdmlzaWJsZUxpc3QoKTsKICAg
ICAgICBpZiAoIXZpcy5sZW5ndGgpIHJldHVybjsKICAgICAgICBpZHggPSBNYXRoLm1heCgwLCBN
YXRoLm1pbih2aXMubGVuZ3RoIC0gMSwgaWR4KSk7CiAgICAgICAgc2VsZWN0ZWRJZCA9IHZpc1tp
ZHhdLmlkOwogICAgICAgIHN5bmNJdGVtSGlnaGxpZ2h0KCk7CiAgICAgICAgY29uc3QgZWwgPSBs
aXN0RWwucXVlcnlTZWxlY3RvcignLml0bVtkYXRhLWlkPSInICsgc2VsZWN0ZWRJZCArICciXScp
OwogICAgICAgIGlmIChlbCkgZWwuc2Nyb2xsSW50b1ZpZXcoeyBibG9jazogJ25lYXJlc3QnIH0p
OwogICAgfQoKICAgIGZ1bmN0aW9uIHNlbGVjdGVkSW5kZXgoKSB7CiAgICAgICAgcmV0dXJuIHZp
c2libGVMaXN0KCkuZmluZEluZGV4KGMgPT4gYy5pZCA9PSBzZWxlY3RlZElkKTsKICAgIH0KCiAg
ICBmdW5jdGlvbiBzeW5jSXRlbUhpZ2hsaWdodCgpIHsKICAgICAgICBkb2N1bWVudC5xdWVyeVNl
bGVjdG9yQWxsKCcuaXRtJykuZm9yRWFjaChuID0+IHsKICAgICAgICAgICAgY29uc3QgaWQgPSAr
bi5kYXRhc2V0LmlkOwogICAgICAgICAgICBuLmNsYXNzTGlzdC50b2dnbGUoJ3NlbCcsIGlkID09
IHNlbGVjdGVkSWQpOwogICAgICAgICAgICBuLmNsYXNzTGlzdC50b2dnbGUoJ211bHRpJywgbXVs
dGlJZHMuaW5jbHVkZXMoaWQpKTsKICAgICAgICB9KTsKICAgIH0KCiAgICBmdW5jdGlvbiB1cGRh
dGVNdWx0aUJhZGdlKCkgewogICAgICAgIGNvbnN0IGVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ211bHRpLWNudCcpOwogICAgICAgIGlmIChtdWx0aUlkcy5sZW5ndGggPiAwKSB7CiAgICAg
ICAgICAgIGVsLnRleHRDb250ZW50ID0gJ+W3sumAiSAnICsgbXVsdGlJZHMubGVuZ3RoOwogICAg
ICAgICAgICBlbC5jbGFzc0xpc3QuYWRkKCdvbicpOwogICAgICAgIH0gZWxzZSB7CiAgICAgICAg
ICAgIGVsLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7CiAgICAgICAgfQogICAgICAgIHN5bmNJdGVt
SGlnaGxpZ2h0KCk7CiAgICB9CgogICAgZnVuY3Rpb24gY2xlYXJNdWx0aSgpIHsKICAgICAgICBt
dWx0aUlkcyA9IFtdOwogICAgICAgIHVwZGF0ZU11bHRpQmFkZ2UoKTsKICAgIH0KCiAgICBmdW5j
dGlvbiB0b2dnbGVNdWx0aShpZCkgewogICAgICAgIGlkID0gK2lkOwogICAgICAgIGNvbnN0IGkg
PSBtdWx0aUlkcy5pbmRleE9mKGlkKTsKICAgICAgICBpZiAoaSA+PSAwKSBtdWx0aUlkcy5zcGxp
Y2UoaSwgMSk7CiAgICAgICAgZWxzZSBtdWx0aUlkcy5wdXNoKGlkKTsKICAgICAgICBzZWxlY3Rl
ZElkID0gaWQ7CiAgICAgICAgdXBkYXRlTXVsdGlCYWRnZSgpOwogICAgfQoKICAgIGZ1bmN0aW9u
IHJlbmRlcigpIHsKICAgICAgICBjb25zdCB2aXNpYmxlID0gdmlzaWJsZUxpc3QoKTsKICAgICAg
ICBjb25zdCBwaW5uZWROID0gYWxsQ2xpcHMuZmlsdGVyKGMgPT4gaXNQaW5uZWQoYykpLmxlbmd0
aDsKICAgICAgICBjb25zdCBwaW5DbnQgID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Bpbi1j
bnQnKTsKICAgICAgICBwaW5DbnQudGV4dENvbnRlbnQgICA9IHBpbm5lZE47CiAgICAgICAgcGlu
Q250LnN0eWxlLmRpc3BsYXkgPSBwaW5uZWROID8gJycgOiAnbm9uZSc7CiAgICAgICAgZG9jdW1l
bnQuZ2V0RWxlbWVudEJ5SWQoJ2Jhci10eHQnKS50ZXh0Q29udGVudCAgID0gdmlzaWJsZS5sZW5n
dGggKyAnIOadoSc7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2VtcHR5LXR4dCcp
LnRleHRDb250ZW50ID0gRU1QVFlfTVNHW2N1clRhYl0gfHwgRU1QVFlfTVNHLmFsbDsKCiAgICAg
ICAgY29uc3QgaWRTZXQgPSBuZXcgU2V0KGFsbENsaXBzLm1hcChjID0+ICtjLmlkKSk7CiAgICAg
ICAgbXVsdGlJZHMgPSBtdWx0aUlkcy5maWx0ZXIoaWQgPT4gaWRTZXQuaGFzKGlkKSk7CiAgICAg
ICAgdXBkYXRlTXVsdGlCYWRnZSgpOwoKICAgICAgICBsaXN0RWwucXVlcnlTZWxlY3RvckFsbCgn
Lml0bScpLmZvckVhY2goZSA9PiBlLnJlbW92ZSgpKTsKICAgICAgICBpZiAoIXZpc2libGUubGVu
Z3RoKSB7IGVtcHR5RWwuY2xhc3NMaXN0LmFkZCgnb24nKTsgdXBkYXRlVG9wQnRuKCk7IHJldHVy
bjsgfQogICAgICAgIGVtcHR5RWwuY2xhc3NMaXN0LnJlbW92ZSgnb24nKTsKICAgICAgICBjb25z
dCBmcmFnID0gZG9jdW1lbnQuY3JlYXRlRG9jdW1lbnRGcmFnbWVudCgpOwogICAgICAgIHZpc2li
bGUuZm9yRWFjaCgoYywgaSkgPT4gZnJhZy5hcHBlbmRDaGlsZChtYWtlSXRlbShjLCBpICsgMSkp
KTsKICAgICAgICBsaXN0RWwuYXBwZW5kQ2hpbGQoZnJhZyk7CiAgICAgICAgaWYgKCF2aXNpYmxl
LnNvbWUoYyA9PiBjLmlkID09IHNlbGVjdGVkSWQpKSBzZWxlY3RlZElkID0gdmlzaWJsZVswXS5p
ZDsKICAgICAgICBzeW5jSXRlbUhpZ2hsaWdodCgpOwogICAgICAgIHVwZGF0ZVRvcEJ0bigpOwog
ICAgfQoKICAgIGNvbnN0IFNWRyA9IHsKICAgICAgICB0ZXh0OiAgIGA8c3ZnIHZpZXdCb3g9IjAg
MCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0i
MiI+PHBhdGggZD0iTTQgN1Y0aDE2djNNOSAyMGg2TTEyIDR2MTYiLz48L3N2Zz5gLAogICAgICAg
IGltYWdlOiAgYDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1
cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxyZWN0IHg9IjMiIHk9IjUiIHdpZHRoPSIx
OCIgaGVpZ2h0PSIxNCIgcng9IjIiLz48Y2lyY2xlIGN4PSI4LjUiIGN5PSIxMCIgcj0iMS41IiBm
aWxsPSJjdXJyZW50Q29sb3IiIHN0cm9rZT0ibm9uZSIvPjxwYXRoIGQ9Ik0zIDE2bDUtNSA0IDQg
My0zIDYgNiIvPjwvc3ZnPmAsCiAgICAgICAgZm9sZGVyOiBgPHN2ZyB2aWV3Qm94PSIwIDAgMjQg
MjQiIGZpbGw9ImN1cnJlbnRDb2xvciI+PHBhdGggZD0iTTEwIDRINGMtMS4xIDAtMiAuOS0yIDJ2
MTJjMCAxLjEuOSAyIDIgMmgxNmMxLjEgMCAyLS45IDItMlY4YzAtMS4xLS45LTItMi0yaC04bC0y
LTJ6Ii8+PC9zdmc+YCwKICAgICAgICB6aXA6ICAgIGA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIg
ZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44Ij48cGF0
aCBkPSJNNiAzaDlsNSA1djEzYTEgMSAwIDAgMS0xIDFINmExIDEgMCAwIDEtMS0xVjRhMSAxIDAg
MCAxIDEtMXoiLz48cGF0aCBkPSJNMTQgM3Y2aDYiLz48L3N2Zz5gLAogICAgICAgIGFoazogICAg
YDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJjdXJyZW50Q29sb3IiPjx0ZXh0IHg9IjEy
IiB5PSIxNyIgdGV4dC1hbmNob3I9Im1pZGRsZSIgZm9udC1zaXplPSIxNCIgZm9udC13ZWlnaHQ9
IjcwMCI+SDwvdGV4dD48L3N2Zz5gLAogICAgICAgIGxuazogICAgYDxzdmcgdmlld0JveD0iMCAw
IDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIx
LjgiPjxwYXRoIGQ9Ik0xMCAxM2E1IDUgMCAwIDAgNy4wNyAwbDIuMTItMi4xMmE1IDUgMCAwIDAt
Ny4wNy03LjA3TDExIDUiLz48cGF0aCBkPSJNMTQgMTFhNSA1IDAgMCAwLTcuMDcgMEw0LjggMTMu
MTJhNSA1IDAgMSAwIDcuMDcgNy4wN0wxMyAxOSIvPjwvc3ZnPmAsCiAgICAgICAgZG9jOiAgICBg
PHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9y
IiBzdHJva2Utd2lkdGg9IjEuOCI+PHBhdGggZD0iTTcgM2g3bDUgNXYxM2ExIDEgMCAwIDEtMSAx
SDdhMSAxIDAgMCAxLTEtMVY0YTEgMSAwIDAgMSAxLTF6Ii8+PHBhdGggZD0iTTE0IDN2Nmg2Ii8+
PC9zdmc+YCwKICAgICAgICBtdWx0aTogIGA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0i
bm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44Ij48cmVjdCB4PSI3
IiB5PSI3IiB3aWR0aD0iMTIiIGhlaWdodD0iMTQiIHJ4PSIxLjUiLz48cGF0aCBkPSJNNSAxN1Y1
YTEgMSAwIDAgMSAxLTFoMTAiLz48L3N2Zz5gCiAgICB9OwoKICAgIGZ1bmN0aW9uIGZpbGVFeHQo
cGF0aCkgewogICAgICAgIGNvbnN0IGJhc2UgPSBTdHJpbmcocGF0aCB8fCAnJykuc3BsaXQoL1tc
XC9dLykucG9wKCkgfHwgJyc7CiAgICAgICAgY29uc3QgaSA9IGJhc2UubGFzdEluZGV4T2YoJy4n
KTsKICAgICAgICByZXR1cm4gaSA+IDAgPyBiYXNlLnNsaWNlKGkgKyAxKS50b0xvd2VyQ2FzZSgp
IDogJyc7CiAgICB9CiAgICBjb25zdCBpc0ltYWdlRXh0ID0gZSA9PiBbJ3BuZycsJ2pwZycsJ2pw
ZWcnLCdnaWYnLCd3ZWJwJywnYm1wJywnaWNvJywndGlmJywndGlmZicsJ3N2ZyddLmluY2x1ZGVz
KGUpOwogICAgY29uc3QgaXNaaXBFeHQgICA9IGUgPT4gWyd6aXAnLCdyYXInLCc3eicsJ3Rhcics
J2d6JywnYnoyJ10uaW5jbHVkZXMoZSk7CgogICAgZnVuY3Rpb24gaWNvbkZvckZpbGVzKGZpbGVz
KSB7CiAgICAgICAgaWYgKCFmaWxlcy5sZW5ndGgpICAgIHJldHVybiB7IGNsczogJ2ZpbGUgZnQt
ZG9jJywgc3ZnOiBTVkcuZG9jIH07CiAgICAgICAgaWYgKGZpbGVzLmxlbmd0aCA+IDEpIHJldHVy
biB7IGNsczogJ2ZpbGUgZnQtbG5rJywgc3ZnOiBTVkcubXVsdGkgfTsKICAgICAgICBjb25zdCBl
eHQgPSBmaWxlRXh0KGZpbGVzWzBdKTsKICAgICAgICBpZiAoIWV4dCkgICAgICAgICAgICAgIHJl
dHVybiB7IGNsczogJ2ZpbGUgZnQtZGlyJywgc3ZnOiBTVkcuZm9sZGVyIH07CiAgICAgICAgaWYg
KGlzSW1hZ2VFeHQoZXh0KSkgICByZXR1cm4geyBjbHM6ICdmaWxlIGZ0LWltZycsIHN2ZzogU1ZH
LmltYWdlIH07CiAgICAgICAgaWYgKGlzWmlwRXh0KGV4dCkpICAgICByZXR1cm4geyBjbHM6ICdm
aWxlIGZ0LXppcCcsIHN2ZzogU1ZHLnppcCB9OwogICAgICAgIGlmIChleHQgPT09ICdhaGsnKSAg
ICAgcmV0dXJuIHsgY2xzOiAnZmlsZSBmdC1haGsnLCBzdmc6IFNWRy5haGsgfTsKICAgICAgICBp
ZiAoZXh0ID09PSAnbG5rJykgICAgIHJldHVybiB7IGNsczogJ2ZpbGUgZnQtbG5rJywgc3ZnOiBT
VkcubG5rIH07CiAgICAgICAgcmV0dXJuIHsgY2xzOiAnZmlsZSBmdC1kb2MnLCBzdmc6IFNWRy5k
b2MgfTsKICAgIH0KCiAgICBmdW5jdGlvbiBtYWtlSXRlbShjLCBpZHgpIHsKICAgICAgICBjb25z
dCB0eXBlICAgPSBub3JtVHlwZShjLnR5cGUpOwogICAgICAgIGNvbnN0IHBpbm5lZCA9IGlzUGlu
bmVkKGMpOwogICAgICAgIGNvbnN0IGVsICAgICA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2Rp
dicpOwogICAgICAgIGVsLmNsYXNzTmFtZSAgPSAnaXRtJwogICAgICAgICAgICArIChzZWxlY3Rl
ZElkID09IGMuaWQgPyAnIHNlbCcgOiAnJykKICAgICAgICAgICAgKyAobXVsdGlJZHMuaW5jbHVk
ZXMoK2MuaWQpID8gJyBtdWx0aScgOiAnJyk7CiAgICAgICAgZWwuZGF0YXNldC5pZCA9IGMuaWQ7
CgogICAgICAgIGNvbnN0IGljbyAgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAg
ICAgICBjb25zdCBib2R5ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAg
Ym9keS5jbGFzc05hbWUgPSAnaS1ib2R5JzsKCiAgICAgICAgaWYgKHR5cGUgPT09ICdpbWFnZScp
IHsKICAgICAgICAgICAgaWNvLmNsYXNzTmFtZSA9ICdpLWljbyBpbWFnZSc7CiAgICAgICAgICAg
IGljby5pbm5lckhUTUwgPSBTVkcuaW1hZ2U7CiAgICAgICAgICAgIGNvbnN0IHdyYXAgPSBkb2N1
bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgd3JhcC5jbGFzc05hbWUgPSAn
aS10aHVtYi13cmFwJzsKICAgICAgICAgICAgY29uc3QgaW1nICA9IGRvY3VtZW50LmNyZWF0ZUVs
ZW1lbnQoJ2ltZycpOwogICAgICAgICAgICBpbWcuY2xhc3NOYW1lID0gJ2ktdGh1bWInOwogICAg
ICAgICAgICBpbWcuc3JjID0gYy5kYXRhIHx8ICcnOwogICAgICAgICAgICBpbWcuYWx0ID0gJyc7
CiAgICAgICAgICAgIGltZy5vbmxvYWQgPSAoKSA9PiB7CiAgICAgICAgICAgICAgICBjb25zdCBt
dyA9IHdyYXAuY2xpZW50V2lkdGggfHwgMzAwOwogICAgICAgICAgICAgICAgY29uc3QgbncgPSBp
bWcubmF0dXJhbFdpZHRoICB8fCAwOwogICAgICAgICAgICAgICAgY29uc3QgbmggPSBpbWcubmF0
dXJhbEhlaWdodCB8fCAwOwogICAgICAgICAgICAgICAgaWYgKCFudyB8fCAhbmgpIHJldHVybjsK
ICAgICAgICAgICAgICAgIGNvbnN0IHNjYWxlID0gTWF0aC5taW4oMSwgMTgwIC8gbmgsIG13IC8g
bncpOwogICAgICAgICAgICAgICAgaW1nLnN0eWxlLndpZHRoICA9IE1hdGgucm91bmQobncgKiBz
Y2FsZSkgKyAncHgnOwogICAgICAgICAgICAgICAgaW1nLnN0eWxlLmhlaWdodCA9IE1hdGgucm91
bmQobmggKiBzY2FsZSkgKyAncHgnOwogICAgICAgICAgICB9OwogICAgICAgICAgICB3cmFwLmFw
cGVuZENoaWxkKGltZyk7CiAgICAgICAgICAgIGNvbnN0IG1ldGEgPSBkb2N1bWVudC5jcmVhdGVF
bGVtZW50KCdkaXYnKTsKICAgICAgICAgICAgbWV0YS5jbGFzc05hbWUgPSAnaS1tZXRhJzsKICAg
ICAgICAgICAgbWV0YS5pbm5lckhUTUwgID0gYDxzcGFuIGNsYXNzPSJpLXRpbWUiPiR7YWdvKGMu
dGltZSl9PC9zcGFuPjxzcGFuIGNsYXNzPSJpLW1ldGEtY2VudGVyIj48L3NwYW4+PGRpdiBjbGFz
cz0iaS1tZXRhLXJpZ2h0Ij4ke2Mud2lkdGggPyBgPHNwYW4gY2xhc3M9ImktdGFnIj4ke2Mud2lk
dGh9w5cke2MuaGVpZ2h0fSBweDwvc3Bhbj5gIDogJyd9PC9kaXY+YDsKICAgICAgICAgICAgYm9k
eS5hcHBlbmRDaGlsZCh3cmFwKTsKICAgICAgICAgICAgYm9keS5hcHBlbmRDaGlsZChtZXRhKTsK
ICAgICAgICB9IGVsc2UgaWYgKHR5cGUgPT09ICdmaWxlJykgewogICAgICAgICAgICBjb25zdCBm
aWxlcyA9IFN0cmluZyhjLnByZXZpZXcgfHwgYy5kYXRhIHx8ICcnKS5zcGxpdCgvXHI/XG4vKS5m
aWx0ZXIoQm9vbGVhbik7CiAgICAgICAgICAgIGNvbnN0IGljICAgID0gaWNvbkZvckZpbGVzKGZp
bGVzKTsKICAgICAgICAgICAgaWNvLmNsYXNzTmFtZSA9ICdpLWljbyAnICsgaWMuY2xzOwogICAg
ICAgICAgICBpY28uaW5uZXJIVE1MID0gaWMuc3ZnOwogICAgICAgICAgICBjb25zdCBuYW1lID0g
ZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAgICAgICAgIG5hbWUuY2xhc3NOYW1l
ICA9ICdpLW5hbWUnOwogICAgICAgICAgICBuYW1lLnRleHRDb250ZW50ID0gZmlsZXMubWFwKGYg
PT4gZi5zcGxpdCgvW1xcL10vKS5wb3AoKSkuam9pbignXG4nKSB8fCAnKOaWh+S7tiknOwogICAg
ICAgICAgICBjb25zdCBtZXRhID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICAg
ICAgICAgIG1ldGEuY2xhc3NOYW1lID0gJ2ktbWV0YSc7CiAgICAgICAgICAgIG1ldGEuaW5uZXJI
VE1MICA9IGA8c3BhbiBjbGFzcz0iaS10aW1lIj4ke2FnbyhjLnRpbWUpfTwvc3Bhbj48c3BhbiBj
bGFzcz0iaS1tZXRhLWNlbnRlciI+PC9zcGFuPjxkaXYgY2xhc3M9ImktbWV0YS1yaWdodCI+PHNw
YW4gY2xhc3M9ImktdGFnIj4ke2MuZmlsZUNvdW50IHx8IGZpbGVzLmxlbmd0aCB8fCAxfSDkuKrm
lofku7Y8L3NwYW4+PC9kaXY+YDsKICAgICAgICAgICAgYm9keS5hcHBlbmRDaGlsZChuYW1lKTsK
ICAgICAgICAgICAgYm9keS5hcHBlbmRDaGlsZChtZXRhKTsKICAgICAgICB9IGVsc2UgewogICAg
ICAgICAgICBpY28uY2xhc3NOYW1lID0gJ2ktaWNvIHRleHQnOwogICAgICAgICAgICBpY28uaW5u
ZXJIVE1MID0gU1ZHLnRleHQ7CiAgICAgICAgICAgIGNvbnN0IHR4dCAgPSBjLnByZXZpZXcgfHwg
Yy5kYXRhIHx8ICcnOwogICAgICAgICAgICBjb25zdCBwcmV2ID0gZG9jdW1lbnQuY3JlYXRlRWxl
bWVudCgnZGl2Jyk7CiAgICAgICAgICAgIHByZXYuY2xhc3NOYW1lICA9ICdpLXByZXYnICsgKGlz
VXJsKHR4dCkgPyAnIHVybCcgOiAnJyk7CiAgICAgICAgICAgIHByZXYudGV4dENvbnRlbnQgPSB0
eHQ7CgogICAgICAgICAgICBjb25zdCBtZXRhID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2
Jyk7CiAgICAgICAgICAgIG1ldGEuY2xhc3NOYW1lID0gJ2ktbWV0YSc7CgogICAgICAgICAgICBs
ZXQgcmlnaHRIVE1MID0gJyc7CiAgICAgICAgICAgIGlmIChjLmNoYXJDb3VudCkgcmlnaHRIVE1M
ICs9IGA8c3BhbiBjbGFzcz0iaS10YWciPiR7Yy5jaGFyQ291bnR9IOWtl+espjwvc3Bhbj5gOwog
ICAgICAgICAgICBpZiAocGlubmVkKSAgICAgIHJpZ2h0SFRNTCArPSBgPHNwYW4gY2xhc3M9Imkt
dGFnIj7mlLbol488L3NwYW4+YDsKICAgICAgICAgICAgaWYgKGlzTWFya2Rvd24oYy5kYXRhIHx8
ICcnKSkgcmlnaHRIVE1MICs9IGA8c3BhbiBjbGFzcz0iaS10YWcgbWQtYmFkZ2UiPk1EPC9zcGFu
PmA7CgogICAgICAgICAgICBtZXRhLmlubmVySFRNTCA9CiAgICAgICAgICAgICAgICBgPHNwYW4g
Y2xhc3M9ImktdGltZSI+JHthZ28oYy50aW1lKX08L3NwYW4+YCArCiAgICAgICAgICAgICAgICBg
PHNwYW4gY2xhc3M9ImktbWV0YS1jZW50ZXIiPjxidXR0b24gY2xhc3M9ImktZXhwYW5kLWJ0biIg
dHlwZT0iYnV0dG9uIiB0aXRsZT0i5bGV5byAL+aUtui1tyI+YCArCiAgICAgICAgICAgICAgICBg
PHN2ZyB2aWV3Qm94PSIwIDAgMTYgMTYiIHdpZHRoPSIxMCIgaGVpZ2h0PSIxMCIgZmlsbD0ibm9u
ZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44IiBzdHJva2UtbGluZWNh
cD0icm91bmQiPmAgKwogICAgICAgICAgICAgICAgYDxwb2x5bGluZSBwb2ludHM9IjQgNiA4IDEw
IDEyIDYiLz48L3N2Zz7lsZXlvIA8L2J1dHRvbj48L3NwYW4+YCArCiAgICAgICAgICAgICAgICBg
PGRpdiBjbGFzcz0iaS1tZXRhLXJpZ2h0Ij4ke3JpZ2h0SFRNTH08L2Rpdj5gOwoKICAgICAgICAg
ICAgYm9keS5hcHBlbmRDaGlsZChwcmV2KTsKICAgICAgICAgICAgYm9keS5hcHBlbmRDaGlsZCht
ZXRhKTsKCiAgICAgICAgICAgIGNvbnN0IGV4cEJ0biA9IG1ldGEucXVlcnlTZWxlY3RvcignLmkt
ZXhwYW5kLWJ0bicpOwogICAgICAgICAgICBpZiAoZXhwQnRuKSB7CiAgICAgICAgICAgICAgICBl
eHBCdG4ub25jbGljayA9IGUgPT4gewogICAgICAgICAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0
aW9uKCk7CiAgICAgICAgICAgICAgICAgICAgY29uc3QgZXhwYW5kZWQgPSBwcmV2LmNsYXNzTGlz
dC50b2dnbGUoJ2V4cGFuZGVkJyk7CiAgICAgICAgICAgICAgICAgICAgZXhwQnRuLmlubmVySFRN
TCA9IGV4cGFuZGVkCiAgICAgICAgICAgICAgICAgICAgICAgID8gYDxzdmcgdmlld0JveD0iMCAw
IDE2IDE2IiB3aWR0aD0iMTAiIGhlaWdodD0iMTAiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVu
dENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIj48cG9seWxp
bmUgcG9pbnRzPSI0IDEwIDggNiAxMiAxMCIvPjwvc3ZnPuaUtui1t2AKICAgICAgICAgICAgICAg
ICAgICAgICAgOiBgPHN2ZyB2aWV3Qm94PSIwIDAgMTYgMTYiIHdpZHRoPSIxMCIgaGVpZ2h0PSIx
MCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44IiBz
dHJva2UtbGluZWNhcD0icm91bmQiPjxwb2x5bGluZSBwb2ludHM9IjQgNiA4IDEwIDEyIDYiLz48
L3N2Zz7lsZXlvIBgOwogICAgICAgICAgICAgICAgfTsKICAgICAgICAgICAgICAgIGNvbnN0IGNo
ZWNrT3ZlcmZsb3cgPSAoKSA9PiB7CiAgICAgICAgICAgICAgICAgICAgaWYgKHByZXYuc2Nyb2xs
SGVpZ2h0ID4gcHJldi5jbGllbnRIZWlnaHQgKyAyKQogICAgICAgICAgICAgICAgICAgICAgICBl
eHBCdG4uY2xhc3NMaXN0LmFkZCgnb24nKTsKICAgICAgICAgICAgICAgICAgICBlbHNlCiAgICAg
ICAgICAgICAgICAgICAgICAgIGV4cEJ0bi5jbGFzc0xpc3QucmVtb3ZlKCdvbicpOwogICAgICAg
ICAgICAgICAgfTsKICAgICAgICAgICAgICAgIHJlcXVlc3RBbmltYXRpb25GcmFtZShjaGVja092
ZXJmbG93KTsKICAgICAgICAgICAgICAgIHNldFRpbWVvdXQoY2hlY2tPdmVyZmxvdywgODApOwog
ICAgICAgICAgICB9CiAgICAgICAgfQoKICAgICAgICBjb25zdCBudW0gPSBkb2N1bWVudC5jcmVh
dGVFbGVtZW50KCdkaXYnKTsKICAgICAgICBudW0uY2xhc3NOYW1lICA9ICdpLW51bSc7CiAgICAg
ICAgbnVtLnRleHRDb250ZW50ID0gaWR4OwoKICAgICAgICBlbC5hcHBlbmRDaGlsZChpY28pOwog
ICAgICAgIGVsLmFwcGVuZENoaWxkKGJvZHkpOwogICAgICAgIGVsLmFwcGVuZENoaWxkKG51bSk7
CgogICAgICAgIGVsLm9uY2xpY2sgPSBlID0+IHsKICAgICAgICAgICAgaWYgKGUuY3RybEtleSB8
fCBlLm1ldGFLZXkpIHsKICAgICAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAg
ICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgICAgICB0b2dnbGVNdWx0
aShjLmlkKTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAgICAgICAg
ICBzZWxlY3RlZElkID0gYy5pZDsKICAgICAgICAgICAgaWYgKG11bHRpSWRzLmxlbmd0aCA+IDAg
JiYgbXVsdGlJZHMuaW5jbHVkZXMoK2MuaWQpKSB7CiAgICAgICAgICAgICAgICBjb25zdCBpZHMg
PSBtdWx0aUlkcy5zbGljZSgpOwogICAgICAgICAgICAgICAgY2xlYXJNdWx0aSgpOwogICAgICAg
ICAgICAgICAgaWYgKGlkcy5sZW5ndGggPiAxKSBhaGsoJ3Bhc3RlTWFueScsIGlkcy5qb2luKCcs
JykpOwogICAgICAgICAgICAgICAgZWxzZSBhaGsoJ3Bhc3RlJywgU3RyaW5nKGlkc1swXSkpOwog
ICAgICAgICAgICAgICAgcmV0dXJuOwogICAgICAgICAgICB9CiAgICAgICAgICAgIGlmIChtdWx0
aUlkcy5sZW5ndGgpIGNsZWFyTXVsdGkoKTsKICAgICAgICAgICAgc3luY0l0ZW1IaWdobGlnaHQo
KTsKICAgICAgICAgICAgYWhrKCdwYXN0ZScsIFN0cmluZyhjLmlkKSk7CiAgICAgICAgfTsKICAg
ICAgICBlbC5vbmNvbnRleHRtZW51ID0gZSA9PiB7CiAgICAgICAgICAgIGUucHJldmVudERlZmF1
bHQoKTsKICAgICAgICAgICAgc2VsZWN0ZWRJZCA9IGMuaWQ7CiAgICAgICAgICAgIHNob3dDdHgo
ZS5jbGllbnRYLCBlLmNsaWVudFksIGMpOwogICAgICAgIH07CgogICAgICAgIHJldHVybiBlbDsK
ICAgIH0KCiAgICBjb25zdCBjdHhFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjdHgnKTsK
ICAgIGZ1bmN0aW9uIHNob3dDdHgoeCwgeSwgYykgewogICAgICAgIGN0eENsaXAgPSBjOwogICAg
ICAgIGN0eEVsLmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAgICAgICAgY3R4RWwuc3R5bGUubGVmdCA9
IHggKyAncHgnOwogICAgICAgIGN0eEVsLnN0eWxlLnRvcCAgPSB5ICsgJ3B4JzsKICAgICAgICBy
ZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4gewogICAgICAgICAgICBjb25zdCByID0gY3R4RWwu
Z2V0Qm91bmRpbmdDbGllbnRSZWN0KCk7CiAgICAgICAgICAgIGlmIChyLnJpZ2h0ICA+IGlubmVy
V2lkdGgpICBjdHhFbC5zdHlsZS5sZWZ0ID0gKHggLSByLndpZHRoKSAgKyAncHgnOwogICAgICAg
ICAgICBpZiAoci5ib3R0b20gPiBpbm5lckhlaWdodCkgY3R4RWwuc3R5bGUudG9wICA9ICh5IC0g
ci5oZWlnaHQpICsgJ3B4JzsKICAgICAgICB9KTsKICAgIH0KICAgIGZ1bmN0aW9uIGhpZGVDdHgo
KSB7IGN0eEVsLmNsYXNzTGlzdC5yZW1vdmUoJ29uJyk7IGN0eENsaXAgPSBudWxsOyB9CgogICAg
ZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBlID0+IHsgaWYgKCFlLnRhcmdldC5j
bG9zZXN0KCcjY3R4JykpIGhpZGVDdHgoKTsgfSk7CiAgICBkb2N1bWVudC5hZGRFdmVudExpc3Rl
bmVyKCdrZXlkb3duJywgZSA9PiB7CiAgICAgICAgLy8gRXNjOiBhbHdheXMgY2xvc2UgcGFuZWwg
KHNlYXJjaCBvciBub3QpOyBwaW4ga2VlcHMgcGFuZWwKICAgICAgICBpZiAoZS5rZXkgPT09ICdF
c2NhcGUnKSB7CiAgICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgaGlk
ZUN0eCgpOwogICAgICAgICAgICBpZiAoIXBpbm5lZFVJKSBhaGsoJ2hpZGUnKTsKICAgICAgICAg
ICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICAvLyBXaGlsZSB0eXBpbmcgaW4gc2VhcmNoOiBD
dHJsK0kvSyBhbmQgYXJyb3dzIG1vdmUgbGlzdCwgZG9uJ3QgbGVhdmUgdGhlIGJveAogICAgICAg
IGlmIChkb2N1bWVudC5hY3RpdmVFbGVtZW50Py5pZCA9PT0gJ3NlYXJjaCcpIHsKICAgICAgICAg
ICAgaWYgKChlLmN0cmxLZXkgfHwgZS5tZXRhS2V5KSAmJiAoZS5rZXkgPT09ICdpJyB8fCBlLmtl
eSA9PT0gJ0knKSkgewogICAgICAgICAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpOyBlLnN0b3BQ
cm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAgd2luZG93Ll9fbmF2ICYmIHdpbmRvdy5fX25h
digndXAnKTsKICAgICAgICAgICAgICAgIHJldHVybjsKICAgICAgICAgICAgfQogICAgICAgICAg
ICBpZiAoKGUuY3RybEtleSB8fCBlLm1ldGFLZXkpICYmIChlLmtleSA9PT0gJ2snIHx8IGUua2V5
ID09PSAnSycpKSB7CiAgICAgICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7IGUuc3RvcFBy
b3BhZ2F0aW9uKCk7CiAgICAgICAgICAgICAgICB3aW5kb3cuX19uYXYgJiYgd2luZG93Ll9fbmF2
KCdkb3duJyk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAg
ICAgaWYgKGUua2V5ID09PSAnQXJyb3dEb3duJykgewogICAgICAgICAgICAgICAgZS5wcmV2ZW50
RGVmYXVsdCgpOyBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAgICAgICAgICAgICAgd2luZG93Ll9f
bmF2ICYmIHdpbmRvdy5fX25hdignZG93bicpOwogICAgICAgICAgICAgICAgcmV0dXJuOwogICAg
ICAgICAgICB9CiAgICAgICAgICAgIGlmIChlLmtleSA9PT0gJ0Fycm93VXAnKSB7CiAgICAgICAg
ICAgICAgICBlLnByZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAg
ICAgICAgICB3aW5kb3cuX19uYXYgJiYgd2luZG93Ll9fbmF2KCd1cCcpOwogICAgICAgICAgICAg
ICAgcmV0dXJuOwogICAgICAgICAgICB9CiAgICAgICAgICAgIHJldHVybjsKICAgICAgICB9CiAg
ICAgICAgY29uc3QgdmlzID0gdmlzaWJsZUxpc3QoKTsKICAgICAgICBpZiAoIXZpcy5sZW5ndGgp
IHJldHVybjsKICAgICAgICBsZXQgaWR4ID0gc2VsZWN0ZWRJbmRleCgpOwogICAgICAgIGlmIChp
ZHggPCAwKSBpZHggPSAwOwogICAgICAgIGlmICAgICAgKGUua2V5ID09PSAnQXJyb3dEb3duJykg
eyBlLnByZXZlbnREZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0aW9uKCk7IHNlbGVjdEJ5SW5kZXgo
aWR4ICsgMSk7IH0KICAgICAgICBlbHNlIGlmIChlLmtleSA9PT0gJ0Fycm93VXAnKSAgIHsgZS5w
cmV2ZW50RGVmYXVsdCgpOyBlLnN0b3BQcm9wYWdhdGlvbigpOyBzZWxlY3RCeUluZGV4KGlkeCAt
IDEpOyB9CiAgICAgICAgZWxzZSBpZiAoZS5rZXkgPT09ICdFbnRlcicpIHsKICAgICAgICAgICAg
ZS5wcmV2ZW50RGVmYXVsdCgpOwogICAgICAgICAgICBpZiAobXVsdGlJZHMubGVuZ3RoID4gMSkg
ewogICAgICAgICAgICAgICAgY29uc3QgaWRzID0gbXVsdGlJZHMuc2xpY2UoKTsKICAgICAgICAg
ICAgICAgIGNsZWFyTXVsdGkoKTsKICAgICAgICAgICAgICAgIGFoaygncGFzdGVNYW55JywgaWRz
LmpvaW4oJywnKSk7CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAg
ICAgICAgaWYgKG11bHRpSWRzLmxlbmd0aCA9PT0gMSkgewogICAgICAgICAgICAgICAgY29uc3Qg
aWQgPSBtdWx0aUlkc1swXTsKICAgICAgICAgICAgICAgIGNsZWFyTXVsdGkoKTsKICAgICAgICAg
ICAgICAgIGFoaygncGFzdGUnLCBTdHJpbmcoaWQpKTsKICAgICAgICAgICAgICAgIHJldHVybjsK
ICAgICAgICAgICAgfQogICAgICAgICAgICBjb25zdCBjID0gdmlzW3NlbGVjdGVkSW5kZXgoKV07
CiAgICAgICAgICAgIGlmIChjKSBhaGsoJ3Bhc3RlJywgU3RyaW5nKGMuaWQpKTsKICAgICAgICB9
IGVsc2UgaWYgKC9eWzEtOV0kLy50ZXN0KGUua2V5KSkgewogICAgICAgICAgICBjb25zdCBjID0g
dmlzWytlLmtleSAtIDFdOwogICAgICAgICAgICBpZiAoYykgYWhrKCdwYXN0ZScsIFN0cmluZyhj
LmlkKSk7CiAgICAgICAgfQogICAgfSk7CgogICAgd2luZG93Ll9fbmF2ID0gZGlyID0+IHsKICAg
ICAgICBjb25zdCB2aXMgPSB2aXNpYmxlTGlzdCgpOwogICAgICAgIGlmICghdmlzLmxlbmd0aCkg
cmV0dXJuOwogICAgICAgIGxldCBpZHggPSBzZWxlY3RlZEluZGV4KCk7CiAgICAgICAgaWYgKGlk
eCA8IDApIGlkeCA9IDA7CiAgICAgICAgaWYgKGRpciA9PT0gJ3VwJykgc2VsZWN0QnlJbmRleChp
ZHggLSAxKTsKICAgICAgICBlbHNlIGlmIChkaXIgPT09ICdkb3duJykgc2VsZWN0QnlJbmRleChp
ZHggKyAxKTsKICAgICAgICBlbHNlIGlmIChkaXIgPT09ICdlbnRlcicpIHsKICAgICAgICAgICAg
aWYgKG11bHRpSWRzLmxlbmd0aCA+IDEpIHsKICAgICAgICAgICAgICAgIGNvbnN0IGlkcyA9IG11
bHRpSWRzLnNsaWNlKCk7CiAgICAgICAgICAgICAgICBjbGVhck11bHRpKCk7CiAgICAgICAgICAg
ICAgICBhaGsoJ3Bhc3RlTWFueScsIGlkcy5qb2luKCcsJykpOwogICAgICAgICAgICAgICAgcmV0
dXJuOwogICAgICAgICAgICB9CiAgICAgICAgICAgIGlmIChtdWx0aUlkcy5sZW5ndGggPT09IDEp
IHsKICAgICAgICAgICAgICAgIGNvbnN0IGlkID0gbXVsdGlJZHNbMF07CiAgICAgICAgICAgICAg
ICBjbGVhck11bHRpKCk7CiAgICAgICAgICAgICAgICBhaGsoJ3Bhc3RlJywgU3RyaW5nKGlkKSk7
CiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIH0KICAgICAgICAgICAgY29uc3Qg
YyA9IHZpc1tzZWxlY3RlZEluZGV4KCldOwogICAgICAgICAgICBpZiAoYykgYWhrKCdwYXN0ZScs
IFN0cmluZyhjLmlkKSk7CiAgICAgICAgfQogICAgfTsKICAgIHdpbmRvdy5fX29uUGFuZWxTaG93
ID0gKCkgPT4gewogICAgICAgIC8vIERvIE5PVCBmb2N1cyBXZWJWaWV3IOKAlCBrZWVwIGVkaXRv
ciBjYXJldC9mb2N1cyAoQUhLIGhhbmRsZXMga2V5cyB2aWEgI0hvdElmKQogICAgICAgIC8vIENv
bGxhcHNlIHNlYXJjaCBVSSBldmVyeSB0aW1lIHRoZSBwYW5lbCBvcGVucwogICAgICAgIHRyeSB7
CiAgICAgICAgICAgIGNvbnN0IHdyYXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VhcmNo
LXdyYXAnKTsKICAgICAgICAgICAgY29uc3Qgc3JjaCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlk
KCdzZWFyY2gnKTsKICAgICAgICAgICAgY29uc3Qgc2NsciA9IGRvY3VtZW50LmdldEVsZW1lbnRC
eUlkKCdzZWFyY2gtY2xyJyk7CiAgICAgICAgICAgIGlmICh3cmFwKSB3cmFwLmNsYXNzTGlzdC5y
ZW1vdmUoJ29wZW4nKTsKICAgICAgICAgICAgaWYgKHNyY2gpIHsKICAgICAgICAgICAgICAgIHNy
Y2gudmFsdWUgPSAnJzsKICAgICAgICAgICAgICAgIHNyY2guY2xhc3NMaXN0LnJlbW92ZSgnaGFz
LXZhbCcpOwogICAgICAgICAgICAgICAgdHJ5IHsgc3JjaC5ibHVyKCk7IH0gY2F0Y2gge30KICAg
ICAgICAgICAgfQogICAgICAgICAgICBpZiAoc2Nscikgc2Nsci5zdHlsZS5kaXNwbGF5ID0gJ25v
bmUnOwogICAgICAgICAgICBxdWVyeSA9ICcnOwogICAgICAgICAgICBhaGsoJ2JsdXJQYW5lbCcp
OwogICAgICAgIH0gY2F0Y2gge30KICAgICAgICBjb25zdCB2aXMgPSB2aXNpYmxlTGlzdCgpOwog
ICAgICAgIGlmICh2aXMubGVuZ3RoICYmICF2aXMuc29tZShjID0+IGMuaWQgPT0gc2VsZWN0ZWRJ
ZCkpCiAgICAgICAgICAgIHNlbGVjdGVkSWQgPSB2aXNbMF0uaWQ7CiAgICAgICAgc3luY0l0ZW1I
aWdobGlnaHQoKTsKICAgICAgICByZW5kZXIoKTsKICAgIH07CgogICAgZnVuY3Rpb24gY3R4Qmlu
ZChpZCwgZm4pIHsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChpZCkuYWRkRXZlbnRM
aXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsK
ICAgICAgICAgICAgaWYgKGN0eENsaXApIGZuKGN0eENsaXApOwogICAgICAgICAgICBoaWRlQ3R4
KCk7CiAgICAgICAgfSk7CiAgICB9CiAgICBjdHhCaW5kKCdjLWNvcHknLCAgYyA9PiBhaGsoJ2Nv
cHlCeUlkJywgICAgIFN0cmluZyhjLmlkKSkpOwogICAgY3R4QmluZCgnYy1wYXN0ZScsIGMgPT4g
YWhrKCdwYXN0ZScsICAgICAgICAgU3RyaW5nKGMuaWQpKSk7CiAgICBjdHhCaW5kKCdjLWZsb2F0
JywgYyA9PiBhaGsoJ2Zsb2F0VHJhbnNmZXInLCBTdHJpbmcoYy5pZCkpKTsKICAgIGN0eEJpbmQo
J2MtcGluJywgICBjID0+IGFoaygncGluJywgICAgICAgICAgIFN0cmluZyhjLmlkKSkpOwogICAg
Y3R4QmluZCgnYy10b3AnLCAgIGMgPT4gYWhrKCdtb3ZlVG9Ub3AnLCAgICAgU3RyaW5nKGMuaWQp
KSk7CiAgICBjdHhCaW5kKCdjLWRlbCcsICAgYyA9PiBhaGsoJ2RlbGV0ZScsICAgICAgICBTdHJp
bmcoYy5pZCkpKTsKCiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGFicycpLmFkZEV2ZW50
TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7CiAgICAgICAgY29uc3QgdGFiID0gZS50YXJnZXQuY2xv
c2VzdCgnLnRhYicpOwogICAgICAgIGlmICghdGFiIHx8IGUudGFyZ2V0LmNsb3Nlc3QoJyN0YWIt
YWN0aW9ucycpKSByZXR1cm47CiAgICAgICAgc2V0VGFiKHRhYi5kYXRhc2V0LnRhYik7CiAgICB9
KTsKCiAgICBjb25zdCBzcmNoV3JhcCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzZWFyY2gt
d3JhcCcpOwogICAgY29uc3QgYnRuU2VhcmNoID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0
bi1zZWFyY2gnKTsKICAgIGNvbnN0IHNyY2ggPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2Vh
cmNoJyk7CiAgICBjb25zdCBzY2xyID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlYXJjaC1j
bHInKTsKICAgIGxldCBkZWI7CgogICAgZnVuY3Rpb24gb3BlblNlYXJjaCgpIHsKICAgICAgICBp
ZiAoc3JjaFdyYXAuY2xhc3NMaXN0LmNvbnRhaW5zKCdvcGVuJykpIHsKICAgICAgICAgICAgYWhr
KCdmb2N1c1BhbmVsJyk7CiAgICAgICAgICAgIHRyeSB7IHNyY2guZm9jdXMoKTsgfSBjYXRjaCB7
fQogICAgICAgICAgICByZXR1cm47CiAgICAgICAgfQogICAgICAgIHNyY2hXcmFwLmNsYXNzTGlz
dC5hZGQoJ29wZW4nKTsKICAgICAgICBhaGsoJ2ZvY3VzUGFuZWwnKTsKICAgICAgICByZXF1ZXN0
QW5pbWF0aW9uRnJhbWUoKCkgPT4gewogICAgICAgICAgICB0cnkgeyBzcmNoLmZvY3VzKCk7IH0g
Y2F0Y2gge30KICAgICAgICB9KTsKICAgIH0KICAgIGZ1bmN0aW9uIGNsb3NlU2VhcmNoVWkoKSB7
CiAgICAgICAgc3JjaFdyYXAuY2xhc3NMaXN0LnJlbW92ZSgnb3BlbicpOwogICAgICAgIGlmICgh
c3JjaC52YWx1ZSkgewogICAgICAgICAgICBzcmNoLmNsYXNzTGlzdC5yZW1vdmUoJ2hhcy12YWwn
KTsKICAgICAgICAgICAgc2Nsci5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOwogICAgICAgIH0KICAg
IH0KICAgIHdpbmRvdy5fX29wZW5TZWFyY2ggPSBvcGVuU2VhcmNoOwogICAgLy8gQ2FwdHVyZSBD
dHJsK0YgaW5zaWRlIFdlYlZpZXcgKENocm9taXVtIGZpbmQgaXMgZGlzYWJsZWQsIGJ1dCBzdGls
bCBoYW5kbGUgaGVyZSkKICAgIGRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIoJ2tleWRvd24nLCBl
ID0+IHsKICAgICAgICBpZiAoKGUuY3RybEtleSB8fCBlLm1ldGFLZXkpICYmICFlLmFsdEtleSAm
JiAoZS5rZXkgPT09ICdmJyB8fCBlLmtleSA9PT0gJ0YnKSkgewogICAgICAgICAgICBlLnByZXZl
bnREZWZhdWx0KCk7CiAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAg
IG9wZW5TZWFyY2goKTsKICAgICAgICB9CiAgICB9LCB0cnVlKTsKICAgIGJ0blNlYXJjaC5hZGRF
dmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7
CiAgICAgICAgb3BlblNlYXJjaCgpOwogICAgfSk7CiAgICBzcmNoLmFkZEV2ZW50TGlzdGVuZXIo
J2lucHV0JywgKCkgPT4gewogICAgICAgIHF1ZXJ5ID0gc3JjaC52YWx1ZTsKICAgICAgICBzcmNo
LmNsYXNzTGlzdC50b2dnbGUoJ2hhcy12YWwnLCAhIXF1ZXJ5KTsKICAgICAgICBzY2xyLnN0eWxl
LmRpc3BsYXkgPSBxdWVyeSA/ICdibG9jaycgOiAnbm9uZSc7CiAgICAgICAgY2xlYXJUaW1lb3V0
KGRlYik7CiAgICAgICAgZGViID0gc2V0VGltZW91dChyZW5kZXIsIDUwKTsKICAgIH0pOwogICAg
c3JjaC5hZGRFdmVudExpc3RlbmVyKCdmb2N1cycsICgpID0+IHsKICAgICAgICBhaGsoJ2ZvY3Vz
UGFuZWwnKTsKICAgIH0pOwogICAgc3JjaC5hZGRFdmVudExpc3RlbmVyKCdibHVyJywgKCkgPT4g
ewogICAgICAgIHNldFRpbWVvdXQoKCkgPT4gewogICAgICAgICAgICBpZiAoZG9jdW1lbnQuYWN0
aXZlRWxlbWVudCA9PT0gc3JjaCkgcmV0dXJuOwogICAgICAgICAgICAvLyBDbGVhciBidXR0b24g
Y2xpY2sgYmx1cnMgdGhlbiByZWZvY3VzZXMg4oCUIGRvbid0IGNvbGxhcHNlIHlldAogICAgICAg
ICAgICBpZiAoZG9jdW1lbnQuYWN0aXZlRWxlbWVudCA9PT0gc2NsciB8fCBzY2xyLmNvbnRhaW5z
KGRvY3VtZW50LmFjdGl2ZUVsZW1lbnQpKSByZXR1cm47CiAgICAgICAgICAgIGNsb3NlU2VhcmNo
VWkoKTsKICAgICAgICAgICAgYWhrKCdibHVyUGFuZWwnKTsKICAgICAgICB9LCAxMjApOwogICAg
fSk7CiAgICBzcmNoLmFkZEV2ZW50TGlzdGVuZXIoJ2tleWRvd24nLCBlID0+IHsKICAgICAgICAv
LyBDdHJsK0kgLyBDdHJsK0s6IG1vdmUgY2xpcCBzZWxlY3Rpb24gKG5vdCBpbnNlcnQgY2hhciAv
IGJyb3dzZXIgc2hvcnRjdXQpCiAgICAgICAgaWYgKChlLmN0cmxLZXkgfHwgZS5tZXRhS2V5KSAm
JiAoZS5rZXkgPT09ICdpJyB8fCBlLmtleSA9PT0gJ0knKSkgewogICAgICAgICAgICBlLnByZXZl
bnREZWZhdWx0KCk7CiAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAg
IHdpbmRvdy5fX25hdiAmJiB3aW5kb3cuX19uYXYoJ3VwJyk7CiAgICAgICAgICAgIHJldHVybjsK
ICAgICAgICB9CiAgICAgICAgaWYgKChlLmN0cmxLZXkgfHwgZS5tZXRhS2V5KSAmJiAoZS5rZXkg
PT09ICdrJyB8fCBlLmtleSA9PT0gJ0snKSkgewogICAgICAgICAgICBlLnByZXZlbnREZWZhdWx0
KCk7CiAgICAgICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgICAgIHdpbmRvdy5f
X25hdiAmJiB3aW5kb3cuX19uYXYoJ2Rvd24nKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAg
IH0KICAgICAgICBpZiAoZS5rZXkgPT09ICdBcnJvd0Rvd24nKSB7CiAgICAgICAgICAgIGUucHJl
dmVudERlZmF1bHQoKTsKICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICAg
ICAgd2luZG93Ll9fbmF2ICYmIHdpbmRvdy5fX25hdignZG93bicpOwogICAgICAgICAgICByZXR1
cm47CiAgICAgICAgfQogICAgICAgIGlmIChlLmtleSA9PT0gJ0Fycm93VXAnKSB7CiAgICAgICAg
ICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsK
ICAgICAgICAgICAgd2luZG93Ll9fbmF2ICYmIHdpbmRvdy5fX25hdigndXAnKTsKICAgICAgICAg
ICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBpZiAoZS5rZXkgPT09ICdFc2NhcGUnKSB7CiAg
ICAgICAgICAgIGUucHJldmVudERlZmF1bHQoKTsKICAgICAgICAgICAgZS5zdG9wUHJvcGFnYXRp
b24oKTsKICAgICAgICAgICAgLy8gQWx3YXlzIGRpc21pc3MgdGhlIHdob2xlIHBhbmVsIChub3Qg
anVzdCB0aGUgc2VhcmNoIGZpZWxkKQogICAgICAgICAgICBpZiAoIXBpbm5lZFVJKSBhaGsoJ2hp
ZGUnKTsKICAgICAgICAgICAgcmV0dXJuOwogICAgICAgIH0KICAgICAgICBlLnN0b3BQcm9wYWdh
dGlvbigpOwogICAgfSk7CiAgICBzY2xyLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7
CiAgICAgICAgZS5zdG9wUHJvcGFnYXRpb24oKTsKICAgICAgICBzcmNoLnZhbHVlID0gcXVlcnkg
PSAnJzsKICAgICAgICBzY2xyLnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgICAgICAgc3JjaC5j
bGFzc0xpc3QucmVtb3ZlKCdoYXMtdmFsJyk7CiAgICAgICAgcmVuZGVyKCk7CiAgICAgICAgYWhr
KCdmb2N1c1BhbmVsJyk7CiAgICAgICAgc3JjaC5mb2N1cygpOwogICAgfSk7CgogICAgZG9jdW1l
bnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi1jbHInKS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUg
PT4gewogICAgICAgIGUuc3RvcFByb3BhZ2F0aW9uKCk7CiAgICAgICAgYWhrKCdjbGVhcicpOwog
ICAgfSk7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbXVsdGktY250JykuYWRkRXZlbnRM
aXN0ZW5lcignY2xpY2snLCBlID0+IHsKICAgICAgICBlLnN0b3BQcm9wYWdhdGlvbigpOwogICAg
ICAgIGNsZWFyTXVsdGkoKTsKICAgIH0pOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0
bi1waW4nKS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4gewogICAgICAgIGUuc3RvcFBy
b3BhZ2F0aW9uKCk7CiAgICAgICAgcGlubmVkVUkgPSAhcGlubmVkVUk7CiAgICAgICAgZS5jdXJy
ZW50VGFyZ2V0LmNsYXNzTGlzdC50b2dnbGUoJ29uJywgcGlubmVkVUkpOwogICAgICAgIGFoaygn
dG9nZ2xlUGluJywgcGlubmVkVUkgPyAnMScgOiAnMCcpOwogICAgfSk7CgogICAgd2luZG93Ll9f
dXBkYXRlQ2xpcHMgPSBkYXRhID0+IHsKICAgICAgICBhbGxDbGlwcyA9IEFycmF5LmlzQXJyYXko
ZGF0YSkgPyBkYXRhIDogW107CiAgICAgICAgcmVuZGVyKCk7CiAgICB9OwogICAgd2luZG93Ll9f
c2V0UGlubmVkID0gdiA9PiB7CiAgICAgICAgcGlubmVkVUkgPSAhIXY7CiAgICAgICAgZG9jdW1l
bnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi1waW4nKS5jbGFzc0xpc3QudG9nZ2xlKCdvbicsIHBpbm5l
ZFVJKTsKICAgIH07CgogICAgcmVuZGVyKCk7Cjwvc2NyaXB0Pgo8L2JvZHk+CjwvaHRtbD4=
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

OnClipboardChange ClipChanged

; ─────────────────────────────────────────────
;  Panel hotkeys: while panel is open, keys go to clipboard
;  even if the editor still has focus (NoActivate popup)
; ─────────────────────────────────────────────
; Always-on while panel visible (search / pin / unfocused all OK):
;   Ctrl+I/K = move selection, Ctrl+J/L = switch tabs, Ctrl+F = open search
#HotIf ClipPanelIsUp()
$^i::PanelKeyUp("")
$^k::PanelKeyDown("")
$^j::PanelKeyPrevTab("")
$^l::PanelKeyNextTab("")
$^f::PanelOpenSearch("")
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

; ─────────────────────────────────────────────
;  Clipboard
; ─────────────────────────────────────────────
ClipChanged(dataType) {
    global lastTxt, lastImg, clipIgnore
    if clipIgnore || dataType = 0
        return
    Sleep 50

    clipAll := ""
    try {
        ca := ClipboardAll()
        if IsObject(ca) && ca.Size > 0 && ca.Size < 12 * 1024 * 1024
            clipAll := ca
    }

    hasBmp   := DllCall("IsClipboardFormatAvailable", "UInt", 2, "Int")
    hasDib   := DllCall("IsClipboardFormatAvailable", "UInt", 8, "Int")
    hasDib5  := DllCall("IsClipboardFormatAvailable", "UInt", 17, "Int")
    hasFiles := DllCall("IsClipboardFormatAvailable", "UInt", 15, "Int")
    hasImg   := hasBmp || hasDib || hasDib5 || (dataType = 2)

    item := { time: FormatTime(, "yyyy-MM-dd HH:mm:ss"), pinned: false, pasted: false }
    if clipAll != ""
        item.clipAll := clipAll

    if hasImg && !hasFiles {
        img := ClipImageToBase64(&w, &h)
        if img != "" && img != lastImg {
            lastImg := img
            item.type := "image"
            item.data := img
            item.preview := ""
            item.charCount := 0
            item.width := w
            item.height := h
            AddClipItem(item)
            return
        }
        if dataType = 2
            return
    }

    if hasFiles {
        names := GetClipboardFileList()
        if names.Length = 0 {
            raw := A_Clipboard
            if raw = ""
                return
            names := []
            for ln in StrSplit(raw, "`n", "`r") {
                ln := Trim(ln)
                if ln != ""
                    names.Push(ln)
            }
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
        AddClipItem(item)
        return
    }

    if dataType = 1 {
        txt := A_Clipboard
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
    if !item.HasProp("uid") || !item.uid
        item.uid := NextClipUid()
    if item.type = "image" {
        if !item.HasProp("imgFile") || item.imgFile = ""
            item.imgFile := SaveImageToStore(item.data)
        item.data := ""
    } else if item.type = "file" {
        EnsureFileClipThumb(item)
    }
    EnsureSpillPayload(item)
    ; Memory-first: update UI caches immediately, persist disk async
    if item.type = "text" {
        MemoryRemoveTextEqual(item.data)
        lastTxt := item.data
    } else if item.type = "link" {
        old := MemoryTakeLinkEqual(item.data)
        if IsObject(old) {
            if old.HasProp("pasted") && old.pasted
                item.pasted := true
            if old.HasProp("pinned") && old.pinned
                item.pinned := true
            if old.HasProp("linkTitle") && old.linkTitle != ""
                item.linkTitle := old.linkTitle
            if old.HasProp("uid") && old.uid
                item.uid := old.uid
        }
    }
    MemoryInsertFront(item)
    if IsObject(wvCore)
        PushClips(false)
    EnqueueDiskJob(PersistNewItem.Bind(item))
}

AddLinksFromText(text) {
    urls := ExtractUrls(text)
    if urls.Length = 0
        return
    for url in urls
        AddLinkItem(url, false)
    PushClips(false)
}

; On load migrate only — kept for optional tools; runtime link cards come from AddLinksFromText
AddLinksFromTextQuiet(text, &all) {
    urls := ExtractUrls(text)
    if urls.Length = 0
        return
    for url in urls {
        exists := false
        for c in all {
            if c.type = "link" && c.data = url {
                exists := true
                break
            }
        }
        if exists
            continue
        all.Push({
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
        })
    }
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
    if IsObject(old) {
        if old.HasProp("pasted") && old.pasted
            item.pasted := true
        if old.HasProp("pinned") && old.pinned
            item.pinned := true
        if old.HasProp("linkTitle") && old.linkTitle != ""
            item.linkTitle := old.linkTitle
        if old.HasProp("uid") && old.uid
            item.uid := old.uid
    }
    MemoryInsertFront(item)
    if doPush && IsObject(wvCore)
        PushClips(false)
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

; Only when user opens 链接 tab — never during Win+V open
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
    SetTimer(() => PushClips(false), -600)
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

; ─────────────────────────────────────────────
;  Bridge
; ─────────────────────────────────────────────
class ClipBridge {
    ; Defer out of sync WebView host call — sync paste from click re-enters and can paste twice
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
    floatTransfer(id) {
        FloatTransfer(id)
    }
    clearPasted(id) {
        ClearPasted(id)
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
            ; Never remember Start/Search as "previous app" — restoring it covers our panel
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

; Start/Search use a higher z-band — cannot cover them; dismiss the visible overlay only.
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
        if IsShellOverlayHwnd(cur)
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
                    ; Close only the visible Start/Search surface (title 开始 / Search)
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
    ; Only when the large overlay is actually visible — process itself always exists
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
; We cannot draw above Start — prevent Start by delaying LWin until we know it's not Win+V.
HotkeyWinV(*) {
    RememberGoodActiveWin()
    ; Fallback only if Start somehow already visible
    if ShellOverlayIsShowing()
        DismissWindowsSearch()
    delay := IsOneNoteApp() ? -200 : -30
    SetTimer(TogglePanelDeferred, delay)
}

ShowPanel() {
    global guiWin, wv, wvCore, lastCaretX, lastCaretY, hasCaretPos, panelVisible, uiPinned, prevActiveWin, linkMetaPausedUntil

    ; Pause any background title fetching so Win+V stays responsive
    linkMetaPausedUntil := A_TickCount + 2000
    prevActiveWin := ResolvePrevActiveWin(prevActiveWin)

    ; OneNote: bottom-right only — never Acc/UIA/IME/Gui caret
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

        lineGapBelow := 10   ; half of previous 20 — panel under caret
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
    ; Restore previous app focus — never Start/Search (that re-covers our panel)
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
        ; Show first, push data after paint — avoids Win+V freeze on large clip JSON
        try wvCore.ExecuteScriptAsync("window.__onPanelShow && window.__onPanelShow()")
        SetTimer(() => PushClips(false), -30)
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
        try wvCore.ExecuteScriptAsync("window.__nav && window.__nav('enter')")
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

    if IsObject(guiWin) || wvBuilding
        return
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
    global wv, wvCore, HTML_FILE, STORE_DIR, STORE_HOST, CLIP_V1_DIR, wvBuilding, panelVisible
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

        ; Serve clips_store as https://clips.store/... so list thumbs need no base64
        try {
            DirCreate STORE_DIR
            wvCore.SetVirtualHostNameToFolderMapping(STORE_HOST, STORE_DIR, 1)
        }

        try wvCore.InjectAhkComponent()
        wvCore.AddHostObjectToScript("ahk", ClipBridge())

        if !FileExist(HTML_FILE)
            throw Error("找不到界面文件:`n" HTML_FILE)

            wvCore.add_NavigationCompleted((core, args) => (
                ; Warm first VIEW_PAGE_SIZE for every tab, then show 全部
                SetTimer(WarmAllViewsAfterNav, -50),
                SetTimer(() => PushPinStateToUi(), -100)
            ))
        ; Load UI from local embedded HTML only (fully offline)
        wvCore.NavigateToString(FileRead(HTML_FILE, "UTF-8"))
        wvBuilding := false
        ; If user already opened the panel while we were creating, push data once ready
        if panelVisible
            SetTimer(() => (
                IsObject(wv) && (wv.Fill(), wv.IsVisible := true, wv.NotifyParentWindowPositionChanged()),
                PushClips(false)
            ), -80)
    } catch as e {
        wvBuilding := false
        TrayTip("WebView2 init failed", e.Message, "Iconx")
        try FileAppend(FormatTime() " WebView2: " e.Message "`n", CLIP_V1_DIR "\error.log", "UTF-8")
    }
}

WarmAllViewsAfterNav(*) {
    ; One pass fills every tab; 全部 is pushed early mid-scan when ready
    PreloadAllViews("0")
    SetView("all", "", "0")
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
; - OneNote: NEVER any caret probe — even Gui/IME can Critical Error; bottom-right only
; If none found → bottom-right
global cachedCaretX := 0
global cachedCaretY := 0
global cachedCaretTick := 0
global pendingCaretHwnd := 0
global caretWinEventHook := 0
global caretWinEventHookFocus := 0
global caretWinEventCb := 0

GetCaretScreenPos(&cx, &cy, &found := false) {
    cx := 0, cy := 0, found := false
    left := 0, top := 0, right := 0, bottom := 0

    ; Hard skip for OneNote — do not touch its process with caret APIs
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

; Background caret tracker disabled — LOCATIONCHANGE while scrolling made hosts
; auto-scroll an extra notch after the wheel stopped.
StartCaretWatcher() {
    ; no-op (kept so startup/exit still call safely)
}

StopCaretWatcher() {
    global caretWinEventHook, caretWinEventHookFocus, caretWinEventCb
    if caretWinEventHook {
        DllCall("UnhookWinEvent", "Ptr", caretWinEventHook)
        caretWinEventHook := 0
    }
    if caretWinEventHookFocus {
        DllCall("UnhookWinEvent", "Ptr", caretWinEventHookFocus)
        caretWinEventHookFocus := 0
    }
    if caretWinEventCb {
        CallbackFree(caretWinEventCb)
        caretWinEventCb := 0
    }
}

OnCaretWinEvent(hWinEventHook, event, hwnd, idObject, idChild, dwEventThread, dwmsEventTime) {
}

FlushCaretCache(*) {
}

; Same as GetCaretPosEx getCaretPosFromGui — no COM
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
    ; WM_IME_REQUEST=0x0288, IMR_QUERYCHARPOSITION=6 — never block forever
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
    global guiWin, panelVisible, hasCaretPos, searchFocused, dismissSearchUntil
    panelVisible := false
    hasCaretPos := false
    searchFocused := false
    dismissSearchUntil := 0
    SetTimer(KeepSearchDismissed, 0)
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
    scale := A_ScreenHeight / 1080.0
    if scale < 0.75
        scale := 0.75
    if scale > 1.35
        scale := 1.35
    outW := Round(WIN_W_BASE * scale)
    outH := Round(WIN_H_BASE * scale)
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
        if c.type = "image" {
            data := ""
            preview := ""
        } else {
            data := c.data
            preview := c.HasProp("preview") ? c.preview : ""
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
        u := LoadImageFromStore(c.imgFile)
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
        HidePanel()
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
        clipIgnore := true
        try {
            if !SetClipboardFiles(paths)
                return
            MarkItemsPasted(uids)
            HidePanel()
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

    clipIgnore := true
    pastedIds := []
    try {
        HidePanel()
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
    for item in items {
        if item.type = "file" {
            fps := GetItemFilePaths(item)
            if !fps.Length
                return []
            for p in fps
                paths.Push(p)
        } else if item.type = "image" {
            built := BuildAhkNamedPastePaths([item])
            if !built.Length
                return []
            for p in built
                paths.Push(p)
        } else {
            return []
        }
    }
    return paths
}

; Copy clip images/files to temp as ahk_2026-07-19 00-20-31_1.png for Explorer paste names
BuildAhkNamedPastePaths(items) {
    paths := []
    if !IsObject(items) || items.Length < 1
        return paths
    stamp := FormatTime(, "yyyy-MM-dd HH-mm-ss")
    idx := 0
    for item in items {
        src := GetItemFilePath(item)
        if src = ""
            return []
        dotPos := InStr(src, ".", false, -1)
        ext := dotPos > 0 ? StrLower(SubStr(src, dotPos + 1)) : "png"
        if ext = ""
            ext := "png"
        dest := A_Temp "\ahk_" stamp "_" (++idx) "." ext
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
    for ln in StrSplit(String(item.data), "`n", "`r") {
        ln := Trim(ln)
        if ln != "" && FileExist(ln)
            paths.Push(ln)
    }
    return paths
}

; "1" / "0" — simple return for WebView hostObjects (avoids JSON parse issues)
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
    totalChars := 1
    for p in paths {
        if !FileExist(p)
            return false
        totalChars += StrLen(p) + 1
    }
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
; Explorer/Desktop already pastes HDROP/bitmap once — calling PastePngToDir here duplicated files (2→4).
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
    global clips, viewTotal, wvCore
    uid := Integer(uid)
    ; Optimistic UI: remove from memory first, disk later
    imgFile := ""
    itemType := ""
    for c in clips {
        if c.uid = uid {
            if c.HasProp("imgFile")
                imgFile := c.imgFile
            itemType := c.type
            break
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
    for c in clips {
        if c.uid = uid {
            c.pinned := !c.pinned
            newPin := c.pinned
            break
        }
    }
    if !IsSet(newPin) {
        ; Not in current list — still flip on disk/cache via resolve
        it := ResolveClip(uid)
        if !IsObject(it)
            return
        it.pinned := !it.pinned
        newPin := it.pinned
    }
    for key, entry in viewCache {
        for c in entry.items {
            if c.uid = uid {
                c.pinned := newPin
                break
            }
        }
    }
    ; Refresh current view membership for 收藏 tab without full disk scan
    if viewTab = "pinned" || viewQuery != ""
        SetView(viewTab, viewQuery, viewToday ? "1" : "0")
    else if IsObject(wvCore)
        PushClips(false)
    EnqueueDiskJob(DiskSetPinned.Bind(uid, newPin))
}

MarkItemsPasted(uids) {
    global clips
    want := Map()
    for uid in uids
        want[Integer(uid)] := true
    if !want.Count
        return
    if !DiskSetPasted(want, true)
        return
    for c in clips {
        if want.Has(c.uid)
            c.pasted := true
    }
    PushClips(false)
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
    global viewTab, viewQuery, viewToday
    tab := StrLower(Trim(String(tab)))
    scope := StrLower(Trim(String(scope)))
    clearAllDates := (scope = "all")
    today := FormatTime(, "yyyy-MM-dd")
    DiskClearTab(tab, clearAllDates, today)
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

FloatTransfer(uid) {
    item := ResolveClip(uid)
    if !IsObject(item) || item.type != "text"
        return
    fw := Gui("+AlwaysOnTop -Caption +Border +ToolWindow")
    fw.BackColor := "1e1f2e"
    fw.SetFont("s11 cE8EAF0", "Segoe UI")
    preview := SubStr(item.data, 1, 80) (StrLen(item.data) > 80 ? "…" : "")
    fw.Add("Text", "w280 h60 +Wrap", preview)
    fw.Add("Button", "w90 h28 x5 y70", "粘贴").OnEvent("Click", (*) => (
        fw.Destroy(), A_Clipboard := item.data, ClipWait(1), Send("^v")
    ))
    fw.Add("Button", "w90 h28 x100 y70", "关闭").OnEvent("Click", (*) => fw.Destroy())
    fw.Show("NoActivate")
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
        return name
    } catch {
        return ""
    }
}

; Capture foreground (or last non-panel) process icon when text is copied
CaptureClipSrcIcon() {
    global guiWin, prevActiveWin
    hwnd := 0
    try hwnd := WinExist("A")
    if IsObject(guiWin) && guiWin.Hwnd && hwnd = guiWin.Hwnd
        hwnd := prevActiveWin
    if !hwnd
        return { icon: "", exe: "" }
    exePath := ""
    exeName := ""
    try {
        exePath := WinGetProcessPath("ahk_id " hwnd)
        exeName := WinGetProcessName("ahk_id " hwnd)
    }
    if exePath = "" || !FileExist(exePath)
        return { icon: "", exe: exeName }
    return { icon: SaveExeIconToStore(exePath), exe: exeName }
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
        if FileExist(dest)
            return name
        FileCopy path, dest, 1
        if FileExist(dest)
            return name
    } catch {
    }
    return ""
}

EnsureFileClipThumb(item) {
    global STORE_DIR
    if !IsObject(item) || item.type != "file"
        return
    if item.HasProp("imgFile") && item.imgFile != "" && FileExist(STORE_DIR "\" item.imgFile)
        return
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
        name := EnsureFileImageInStore(p, item.uid)
        if name = ""
            continue
        item.imgFile := name
        w := 0, h := 0
        GetImageFileDimensions(STORE_DIR "\" name, &w, &h)
        if w > 0 {
            item.width := w
            item.height := h
        }
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
        return "data:image/png;base64," B64Encode(buf)
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

; NDJSON shards (<=PAGE_SIZE lines each) — see ahk\clip_v1\ndjson_pages.ahk
#Include %A_ScriptDir%\ahk\clip_v1\ndjson_pages.ahk
OnExit SaveAndExit
SaveAndExit(*) {
    ; Must flush async disk queue — otherwise last copy (esp. large) is lost on exit
    try FlushDiskJobsSync()
    StopCaretWatcher()
}

EnsureDataDir()
InitClipsFromDisk()

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
; Quick Win+other — still reach the OS
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

; WebView2 is created lazily on first Win+V — avoid spawning Edge at script start

; ─────────────────────────────────────────────
;  Init: create ahk\clip_v1 dirs and write HTML
; ─────────────────────────────────────────────
EnsureDataDir() {
    global CLIP_V1_DIR, HTML_FILE, STORE_DIR, PAGES_DIR, PAYLOAD_DIR
    try DirCreate CLIP_V1_DIR
    try DirCreate STORE_DIR
    try DirCreate PAGES_DIR
    try DirCreate PAYLOAD_DIR
    WriteHtmlFile()
}

WriteHtmlFile() {
    global HTML_FILE, HTML_B64
    ; Only bootstrap missing UI — never overwrite a disk-edited index.html
    if FileExist(HTML_FILE)
        return
    B64DecodeToFile(HTML_B64, HTML_FILE)
}

; ─────────────────────────────────────────────
;  Ctrl+V: save clipboard image(s) into the active folder (not ahk\clip_v1)
; ─────────────────────────────────────────────
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
            ; Skip directories — never copy/create folder trees
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
