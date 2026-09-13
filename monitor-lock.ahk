#Requires AutoHotkey v2.0+
#SingleInstance Force

; AHK Monitor Lock
; Constrains the cursor to the monitor under it while a window is being
; interactively moved or resized. Hold either Shift key to temporarily unlock.

Persistent()

APP_NAME := "AHK Monitor Lock"
STARTUP_LINK := A_Startup "\" APP_NAME ".lnk"
POLL_MS := 10

; Runtime state.
gEnabled := true
gMoveSizeActive := false
gActiveHwnd := 0
gClipOwned := false
gOwnedRect := 0
gWinEventHook := 0
gWinEventCallback := 0

; Register cleanup before doing anything which can acquire cursor confinement.
OnExit(Cleanup, -1)
OnError(GlobalErrorHandler, -1)
OnMessage(0x007E, HandleDisplayChange) ; WM_DISPLAYCHANGE

SetupTray()

try {
    InstallMoveSizeHook()
} catch as err {
    MsgBox("Could not install the Windows move/resize event hook.`n`n" err.Message,
        APP_NAME)
    ExitApp()
}


; -----------------------------------------------------------------------------
; WinEvent move/resize detection
; -----------------------------------------------------------------------------

InstallMoveSizeHook() {
    global gWinEventHook, gWinEventCallback

    static EVENT_SYSTEM_MOVESIZESTART := 0x000A
    static EVENT_SYSTEM_MOVESIZEEND   := 0x000B
    static WINEVENT_OUTOFCONTEXT      := 0x0000
    static WINEVENT_SKIPOWNPROCESS    := 0x0002

    ; WINEVENTPROC has 7 parameters. Keep this callback address alive globally.
    gWinEventCallback := CallbackCreate(WinEventProc, "", 7)

    gWinEventHook := DllCall("User32\SetWinEventHook"
        , "UInt", EVENT_SYSTEM_MOVESIZESTART
        , "UInt", EVENT_SYSTEM_MOVESIZEEND
        , "Ptr", 0
        , "Ptr", gWinEventCallback
        , "UInt", 0
        , "UInt", 0
        , "UInt", WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS
        , "Ptr")

    if !gWinEventHook {
        winErr := A_LastError
        CallbackFree(gWinEventCallback)
        gWinEventCallback := 0
        throw Error("SetWinEventHook failed (Win32 error " winErr ").")
    }
}

WinEventProc(hWinEventHook, event, hwnd, idObject, idChild, idEventThread, eventTime) {
    ; CallbackCreate notes that 32-bit callback parameters can contain undefined
    ; high bits on 64-bit AutoHotkey, so normalise the UINT event value.
    event &= 0xFFFFFFFF

    switch event {
        case 0x000A: ; EVENT_SYSTEM_MOVESIZESTART
            HandleMoveSizeStart(hwnd)
        case 0x000B: ; EVENT_SYSTEM_MOVESIZEEND
            HandleMoveSizeEnd(hwnd)
    }
    return 0
}

HandleMoveSizeStart(hwnd) {
    global gMoveSizeActive, gActiveHwnd, gEnabled

    ; If an earlier end event was somehow missed, clean up our old state first.
    StopActiveMonitoring(false)

    gMoveSizeActive := true
    gActiveHwnd := hwnd

    if gEnabled
        StartActiveMonitoring()
}

HandleMoveSizeEnd(hwnd) {
    global gMoveSizeActive, gActiveHwnd

    ; There can only be one interactive move/size operation on the input desktop
    ; at a time, so any MOVESIZEEND is sufficient reason to release immediately.
    gMoveSizeActive := false
    gActiveHwnd := 0
    StopActiveMonitoring(false)
}


; -----------------------------------------------------------------------------
; Active-operation monitoring
; -----------------------------------------------------------------------------

StartActiveMonitoring() {
    global POLL_MS

    ; Apply the correct state immediately, then poll only while the operation is
    ; active. Windows timer granularity may coalesce this to roughly 10-16 ms.
    ActiveTick()
    SetTimer(ActiveTick, POLL_MS)
}

StopActiveMonitoring(resetMoveState := false) {
    global gMoveSizeActive, gActiveHwnd

    SetTimer(ActiveTick, 0)
    ReleaseOwnedClip()

    if resetMoveState {
        gMoveSizeActive := false
        gActiveHwnd := 0
    }
}

ActiveTick(*) {
    global gEnabled, gMoveSizeActive, gClipOwned

    if !gEnabled || !gMoveSizeActive {
        SetTimer(ActiveTick, 0)
        ReleaseOwnedClip()
        return
    }

    ; Notice if Windows or another application has changed the shared clip rect.
    ; If that happens, stop considering it ours rather than fighting the owner.
    if gClipOwned
        ValidateClipOwnership()

    if IsShiftDown() {
        ; Only release a clip which is still recognisably ours.
        if gClipOwned
            ReleaseOwnedClip()
        return
    }

    ; Shift is up. If we do not currently own the clip, acquire it only when the
    ; cursor is otherwise unrestricted; this avoids overriding another app's clip.
    if !gClipOwned
        TryAcquireCurrentMonitorClip()
}

IsShiftDown() {
    static VK_LSHIFT := 0xA0
    static VK_RSHIFT := 0xA1

    return (DllCall("User32\GetAsyncKeyState", "Int", VK_LSHIFT, "Short") & 0x8000)
        || (DllCall("User32\GetAsyncKeyState", "Int", VK_RSHIFT, "Short") & 0x8000)
}


; -----------------------------------------------------------------------------
; Cursor confinement ownership
; -----------------------------------------------------------------------------

TryAcquireCurrentMonitorClip() {
    global gClipOwned, gOwnedRect

    if gClipOwned
        return true

    ; GetClipCursor returns the full virtual-screen rectangle when unrestricted.
    ; If it is already smaller/different, another application is probably using it.
    if !TryGetClipRect(&currentClip)
        return false

    virtualRect := GetPhysicalVirtualScreenRect()
    if !RectEqual(currentClip, virtualRect)
        return false

    if !TryGetCursorMonitorRect(&monitorRect)
        return false

    if !SetClipRect(monitorRect)
        return false

    gOwnedRect := monitorRect
    gClipOwned := true
    return true
}

ValidateClipOwnership() {
    global gClipOwned, gOwnedRect

    if !gClipOwned
        return false

    ; If querying fails, keep the conservative assumption that our clip still
    ; exists; cleanup will make a best-effort release later.
    if !TryGetClipRect(&currentClip)
        return true

    if RectEqual(currentClip, gOwnedRect)
        return true

    ; Someone else (or a display reconfiguration) changed it. Do not clear it.
    gClipOwned := false
    gOwnedRect := 0
    return false
}

ReleaseOwnedClip() {
    global gClipOwned, gOwnedRect

    if !gClipOwned
        return

    ownedRect := gOwnedRect

    ; Clear our bookkeeping first so an error cannot leave us believing we still
    ; own a shared cursor resource.
    gClipOwned := false
    gOwnedRect := 0

    if TryGetClipRect(&currentClip) {
        ; Only clear it if it still matches the rectangle we installed. If another
        ; application replaced it, leave that application's confinement intact.
        if RectEqual(currentClip, ownedRect)
            SetClipFree()
        return
    }

    ; If GetClipCursor itself failed, best effort favours releasing a clip which
    ; we know we previously installed.
    SetClipFree()
}

SetClipRect(rect) {
    buf := RectToBuffer(rect)
    return !!DllCall("User32\ClipCursor", "Ptr", buf.Ptr, "Int")
}

SetClipFree() {
    return !!DllCall("User32\ClipCursor", "Ptr", 0, "Int")
}

TryGetClipRect(&rect) {
    buf := Buffer(16, 0)
    if !DllCall("User32\GetClipCursor", "Ptr", buf.Ptr, "Int") {
        rect := 0
        return false
    }

    rect := [
        NumGet(buf, 0, "Int"),
        NumGet(buf, 4, "Int"),
        NumGet(buf, 8, "Int"),
        NumGet(buf, 12, "Int")
    ]
    return true
}


; -----------------------------------------------------------------------------
; Monitor geometry (physical-pixel virtual-screen coordinates)
; -----------------------------------------------------------------------------

TryGetCursorMonitorRect(&rect) {
    static MONITOR_DEFAULTTONEAREST := 0x00000002

    oldDpi := PushPerMonitorDpiContext()
    try {
        pt := Buffer(8, 0)
        if !DllCall("User32\GetPhysicalCursorPos", "Ptr", pt.Ptr, "Int") {
            rect := 0
            return false
        }

        x := NumGet(pt, 0, "Int")
        y := NumGet(pt, 4, "Int")

        ; MonitorFromRect avoids having to pass a POINT structure by value.
        pointRect := Buffer(16, 0)
        NumPut("Int", x,     pointRect, 0)
        NumPut("Int", y,     pointRect, 4)
        NumPut("Int", x + 1, pointRect, 8)
        NumPut("Int", y + 1, pointRect, 12)

        hMonitor := DllCall("User32\MonitorFromRect"
            , "Ptr", pointRect.Ptr
            , "UInt", MONITOR_DEFAULTTONEAREST
            , "Ptr")

        if !hMonitor {
            rect := 0
            return false
        }

        ; MONITORINFO is 40 bytes on both 32-bit and 64-bit Windows.
        mi := Buffer(40, 0)
        NumPut("UInt", 40, mi, 0)

        if !DllCall("User32\GetMonitorInfoW", "Ptr", hMonitor, "Ptr", mi.Ptr, "Int") {
            rect := 0
            return false
        }

        ; rcMonitor begins at byte 4. Use the full monitor bounds, not rcWork.
        rect := [
            NumGet(mi, 4, "Int"),
            NumGet(mi, 8, "Int"),
            NumGet(mi, 12, "Int"),
            NumGet(mi, 16, "Int")
        ]
        return true
    } finally {
        PopDpiContext(oldDpi)
    }
}

GetPhysicalVirtualScreenRect() {
    static SM_XVIRTUALSCREEN  := 76
    static SM_YVIRTUALSCREEN  := 77
    static SM_CXVIRTUALSCREEN := 78
    static SM_CYVIRTUALSCREEN := 79

    oldDpi := PushPerMonitorDpiContext()
    try {
        left := DllCall("User32\GetSystemMetrics", "Int", SM_XVIRTUALSCREEN, "Int")
        top := DllCall("User32\GetSystemMetrics", "Int", SM_YVIRTUALSCREEN, "Int")
        width := DllCall("User32\GetSystemMetrics", "Int", SM_CXVIRTUALSCREEN, "Int")
        height := DllCall("User32\GetSystemMetrics", "Int", SM_CYVIRTUALSCREEN, "Int")
        return [left, top, left + width, top + height]
    } finally {
        PopDpiContext(oldDpi)
    }
}

PushPerMonitorDpiContext() {
    ; AutoHotkey v2 is system-DPI-aware by default. Temporarily switching the
    ; calling thread to Per-Monitor-v2 keeps monitor/system-metric coordinates in
    ; physical pixels on mixed-scale displays. Windows 11 always supports -4.
    return DllCall("User32\SetThreadDpiAwarenessContext", "Ptr", -4, "Ptr")
}

PopDpiContext(oldContext) {
    if oldContext
        DllCall("User32\SetThreadDpiAwarenessContext", "Ptr", oldContext, "Ptr")
}

RectToBuffer(rect) {
    buf := Buffer(16, 0)
    NumPut("Int", rect[1], buf, 0)
    NumPut("Int", rect[2], buf, 4)
    NumPut("Int", rect[3], buf, 8)
    NumPut("Int", rect[4], buf, 12)
    return buf
}

RectEqual(a, b) {
    return IsObject(a) && IsObject(b)
        && a[1] = b[1]
        && a[2] = b[2]
        && a[3] = b[3]
        && a[4] = b[4]
}

HandleDisplayChange(*) {
    global gEnabled, gMoveSizeActive

    ; Display changes can reset or invalidate a clip rectangle. Re-evaluate only
    ; during an active operation; otherwise this utility never touches the cursor.
    if !gEnabled || !gMoveSizeActive || IsShiftDown()
        return

    ReleaseOwnedClip()
    TryAcquireCurrentMonitorClip()
}


; -----------------------------------------------------------------------------
; Tray menu and Startup-folder integration
; -----------------------------------------------------------------------------

SetupTray() {
    global APP_NAME, STARTUP_LINK

    A_IconTip := APP_NAME
    tray := A_TrayMenu
    tray.Delete()

    tray.Add("Enabled", ToggleEnabled)
    tray.Add("Start with Windows", ToggleStartup)
    tray.Add()
    tray.Add("Exit", TrayExit)

    tray.Check("Enabled")
    if FileExist(STARTUP_LINK)
        tray.Check("Start with Windows")

    ; With no default item, double-clicking the tray icon does not open AutoHotkey's
    ; hidden main window.
    tray.Default := ""
}

ToggleEnabled(*) {
    global gEnabled, gMoveSizeActive

    gEnabled := !gEnabled

    if gEnabled {
        A_TrayMenu.Check("Enabled")
        if gMoveSizeActive
            StartActiveMonitoring()
    } else {
        A_TrayMenu.Uncheck("Enabled")
        StopActiveMonitoring(false)
    }
}

ToggleStartup(*) {
    global APP_NAME, STARTUP_LINK

    try {
        if FileExist(STARTUP_LINK) {
            FileDelete(STARTUP_LINK)
            A_TrayMenu.Uncheck("Start with Windows")
            return
        }

        if A_IsCompiled {
            target := A_ScriptFullPath
            args := ""
            iconFile := A_ScriptFullPath
        } else {
            target := A_AhkPath
            args := Format("`"{1}`"", A_ScriptFullPath)
            iconFile := A_AhkPath
        }

        FileCreateShortcut(target, STARTUP_LINK, A_ScriptDir, args,
            APP_NAME, iconFile)
        A_TrayMenu.Check("Start with Windows")
    } catch as err {
        ; Keep the checkmark truthful if shortcut creation/deletion failed.
        if FileExist(STARTUP_LINK)
            A_TrayMenu.Check("Start with Windows")
        else
            A_TrayMenu.Uncheck("Start with Windows")

        MsgBox("Could not change the startup setting.`n`n" err.Message, APP_NAME)
    }
}

TrayExit(*) {
    ExitApp()
}


; -----------------------------------------------------------------------------
; Cleanup and error handling
; -----------------------------------------------------------------------------

GlobalErrorHandler(thrown, mode) {
    global gEnabled

    ; Disable the feature and release our clip before AutoHotkey performs its
    ; normal error handling. Do not suppress the original error dialog/behaviour.
    gEnabled := false
    try {
        A_TrayMenu.Uncheck("Enabled")
    }
    try {
        StopActiveMonitoring(true)
    }
    return 0
}

Cleanup(*) {
    global gWinEventHook, gWinEventCallback

    try {
        SetTimer(ActiveTick, 0)
    }
    try {
        ReleaseOwnedClip()
    }

    if gWinEventHook {
        try {
            DllCall("User32\UnhookWinEvent", "Ptr", gWinEventHook, "Int")
        }
        gWinEventHook := 0
    }

    if gWinEventCallback {
        try {
            CallbackFree(gWinEventCallback)
        }
        gWinEventCallback := 0
    }
}
