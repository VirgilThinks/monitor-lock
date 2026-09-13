#Requires AutoHotkey v2.0
#SingleInstance Force

Persistent true

global APP_NAME := "AHK Monitor Lock"

global EVENT_SYSTEM_MOVESIZESTART := 0x000A
global EVENT_SYSTEM_MOVESIZEEND := 0x000B
global WINEVENT_OUTOFCONTEXT := 0x0000
global WINEVENT_SKIPOWNPROCESS := 0x0002
global WM_DISPLAYCHANGE := 0x007E

global VK_LBUTTON := 0x01
global VK_RBUTTON := 0x02
global SM_SWAPBUTTON := 23
global SM_XVIRTUALSCREEN := 76
global SM_YVIRTUALSCREEN := 77
global SM_CXVIRTUALSCREEN := 78
global SM_CYVIRTUALSCREEN := 79
global MONITOR_DEFAULTTONEAREST := 0x00000002
global DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE := -3

global gEnabled := true
global gMoveSizeActive := false
global gMoveSizeWindow := 0
global gBoundaryBypass := false
global gPrimaryButtonVk := VK_LBUTTON
global gSecondaryButtonVk := VK_RBUTTON
global gSecondaryWasDown := false

global gOwnsClip := false
global gOwnedLeft := 0
global gOwnedTop := 0
global gOwnedRight := 0
global gOwnedBottom := 0

global gWinEventCallback := 0
global gWinEventHook := 0
global gStartupShortcut := A_Startup "\AHK Monitor Lock.lnk"

Initialise()


Initialise() {
    global EVENT_SYSTEM_MOVESIZESTART, EVENT_SYSTEM_MOVESIZEEND
    global WINEVENT_OUTOFCONTEXT, WINEVENT_SKIPOWNPROCESS, WM_DISPLAYCHANGE
    global gWinEventCallback, gWinEventHook

    OnExit(CleanupOnExit)
    OnError(CleanupOnUnhandledError)
    OnMessage(WM_DISPLAYCHANGE, HandleDisplayChange)

    ConfigureTray()

    gWinEventCallback := CallbackCreate(WinEventProc, , 7)
    gWinEventHook := DllCall(
        "user32\SetWinEventHook",
        "UInt", EVENT_SYSTEM_MOVESIZESTART,
        "UInt", EVENT_SYSTEM_MOVESIZEEND,
        "Ptr", 0,
        "Ptr", gWinEventCallback,
        "UInt", 0,
        "UInt", 0,
        "UInt", WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS,
        "Ptr"
    )

    if !gWinEventHook {
        errorCode := A_LastError
        CallbackFree(gWinEventCallback)
        gWinEventCallback := 0
        throw OSError(errorCode, "SetWinEventHook")
    }
}


ConfigureTray() {
    global APP_NAME

    A_TrayMenu.Delete()
    A_TrayMenu.Add("Enabled", ToggleEnabled)
    A_TrayMenu.Add("Start with Windows", ToggleStartup)
    A_TrayMenu.Add()
    A_TrayMenu.Add("Exit", ExitRequested)
    A_TrayMenu.Default := "Enabled"
    A_IconTip := APP_NAME

    SyncTrayChecks()
}


SyncTrayChecks() {
    global gEnabled

    if gEnabled
        A_TrayMenu.Check("Enabled")
    else
        A_TrayMenu.Uncheck("Enabled")

    if IsStartupEnabled()
        A_TrayMenu.Check("Start with Windows")
    else
        A_TrayMenu.Uncheck("Start with Windows")
}


ToggleEnabled(*) {
    global gEnabled, gMoveSizeActive

    gEnabled := !gEnabled

    if gEnabled {
        if gMoveSizeActive
            StartGuard()
    } else {
        StopGuard()
    }

    SyncTrayChecks()
}


ToggleStartup(*) {
    global APP_NAME, gStartupShortcut

    try {
        if FileExist(gStartupShortcut) {
            FileDelete(gStartupShortcut)
        } else if A_IsCompiled {
            FileCreateShortcut(
                A_ScriptFullPath,
                gStartupShortcut,
                A_ScriptDir,
                "",
                APP_NAME,
                A_ScriptFullPath
            )
        } else {
            quotedScriptPath := Chr(34) A_ScriptFullPath Chr(34)
            FileCreateShortcut(
                A_AhkPath,
                gStartupShortcut,
                A_ScriptDir,
                quotedScriptPath,
                APP_NAME,
                A_AhkPath
            )
        }
    } catch Error {
        TrayTip("Windows startup could not be changed.", APP_NAME)
    }

    SyncTrayChecks()
}


IsStartupEnabled() {
    global gStartupShortcut
    return FileExist(gStartupShortcut) != ""
}


ExitRequested(*) {
    ExitApp()
}


WinEventProc(
    hWinEventHook,
    event,
    hwnd,
    idObject,
    idChild,
    idEventThread,
    eventTime
) {
    global EVENT_SYSTEM_MOVESIZESTART, EVENT_SYSTEM_MOVESIZEEND
    global gEnabled, gMoveSizeActive, gMoveSizeWindow

    Critical("On")

    try {
        if event = EVENT_SYSTEM_MOVESIZESTART {
            if !hwnd
                return

            if gMoveSizeActive
                StopGuard()

            gMoveSizeActive := true
            gMoveSizeWindow := hwnd

            if gEnabled
                StartGuard()
        } else if event = EVENT_SYSTEM_MOVESIZEEND {
            if !gMoveSizeActive
                return

            if gMoveSizeWindow && hwnd && hwnd != gMoveSizeWindow
                return

            gMoveSizeActive := false
            gMoveSizeWindow := 0
            StopGuard()
        }
    } catch Error as err {
        DisableAfterError(err)
    }
}


StartGuard() {
    global gEnabled, gMoveSizeActive
    global gBoundaryBypass, gSecondaryWasDown, gSecondaryButtonVk

    SetTimer(ActiveDragTick, 0)
    ReleaseOwnedClip()

    if !gEnabled || !gMoveSizeActive
        return

    ResolveLogicalMouseButtons()
    gBoundaryBypass := false

    ; A button already held at move/resize start is not a new toggle press.
    gSecondaryWasDown := IsVirtualButtonDown(gSecondaryButtonVk)

    TryLockToCursorMonitor()
    SetTimer(ActiveDragTick, 10)
}


StopGuard() {
    global gBoundaryBypass, gSecondaryWasDown

    SetTimer(ActiveDragTick, 0)
    ReleaseOwnedClip()
    gBoundaryBypass := false
    gSecondaryWasDown := false
}


ActiveDragTick() {
    global gEnabled, gMoveSizeActive, gBoundaryBypass
    global gPrimaryButtonVk, gSecondaryButtonVk, gSecondaryWasDown

    Critical("On")

    try {
        if !gEnabled || !gMoveSizeActive {
            StopGuard()
            return
        }

        primaryDown := IsVirtualButtonDown(gPrimaryButtonVk)
        secondaryDown := IsVirtualButtonDown(gSecondaryButtonVk)

        ; Observe a fresh secondary-button press while the logical primary
        ; button remains down. Nothing here consumes or remaps the click.
        if primaryDown && secondaryDown && !gSecondaryWasDown {
            gBoundaryBypass := !gBoundaryBypass

            if gBoundaryBypass
                ReleaseOwnedClip()
            else
                TryLockToCursorMonitor()
        }

        gSecondaryWasDown := secondaryDown

        ; Reacquire confinement if Windows temporarily clears our clip
        ; while the move/resize operation remains active.
        if !gBoundaryBypass
            TryLockToCursorMonitor()
    } catch Error as err {
        DisableAfterError(err)
    }
}


ResolveLogicalMouseButtons() {
    global VK_LBUTTON, VK_RBUTTON, SM_SWAPBUTTON
    global gPrimaryButtonVk, gSecondaryButtonVk

    buttonsAreSwapped := DllCall(
        "user32\GetSystemMetrics",
        "Int", SM_SWAPBUTTON,
        "Int"
    )

    if buttonsAreSwapped {
        gPrimaryButtonVk := VK_RBUTTON
        gSecondaryButtonVk := VK_LBUTTON
    } else {
        gPrimaryButtonVk := VK_LBUTTON
        gSecondaryButtonVk := VK_RBUTTON
    }
}


IsVirtualButtonDown(virtualKey) {
    state := DllCall(
        "user32\GetAsyncKeyState",
        "Int", virtualKey,
        "Short"
    )

    ; Use only the high-order current-state bit. The low-order transition bit
    ; is shared across processes and is not reliable.
    return (state & 0x8000) != 0
}


TryLockToCursorMonitor() {
    global gOwnsClip
    global gOwnedLeft, gOwnedTop, gOwnedRight, gOwnedBottom

    previousDpiContext := EnterPhysicalCoordinateContext()

    try {
        currentClip := GetCurrentClipRect()
        if !IsObject(currentClip)
            return false

        if gOwnsClip {
            if RectMatchesOwnedClip(currentClip)
                return true

            ; Another programme or Windows replaced our rectangle.
            ; Do not overwrite an intentional external restriction.
            ClearOwnedClipState()
        }

        if !RectIsVirtualScreen(currentClip)
            return false

        monitorRect := GetCursorMonitorRect()
        if !IsObject(monitorRect)
            return false

        clipBuffer := RectToBuffer(monitorRect)
        if !DllCall("user32\ClipCursor", "Ptr", clipBuffer.Ptr, "Int")
            return false

        gOwnsClip := true
        gOwnedLeft := monitorRect[1]
        gOwnedTop := monitorRect[2]
        gOwnedRight := monitorRect[3]
        gOwnedBottom := monitorRect[4]
        return true
    } finally {
        RestoreCoordinateContext(previousDpiContext)
    }
}


ReleaseOwnedClip() {
    global gOwnsClip

    if !gOwnsClip
        return

    previousDpiContext := EnterPhysicalCoordinateContext()

    try {
        currentClip := GetCurrentClipRect()

        ; ClipCursor has no ownership token. Release only if the current
        ; rectangle is still the one installed by this script. If reading
        ; it fails, favour cleanup because we have last-known ownership.
        if !IsObject(currentClip) || RectMatchesOwnedClip(currentClip)
            DllCall("user32\ClipCursor", "Ptr", 0, "Int")

        ClearOwnedClipState()
    } finally {
        RestoreCoordinateContext(previousDpiContext)
    }
}


EnterPhysicalCoordinateContext() {
    global DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE

    return DllCall(
        "user32\SetThreadDpiAwarenessContext",
        "Ptr", DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE,
        "Ptr"
    )
}


RestoreCoordinateContext(previousDpiContext) {
    if previousDpiContext {
        DllCall(
            "user32\SetThreadDpiAwarenessContext",
            "Ptr", previousDpiContext,
            "Ptr"
        )
    }
}


ClearOwnedClipState() {
    global gOwnsClip
    global gOwnedLeft, gOwnedTop, gOwnedRight, gOwnedBottom

    gOwnsClip := false
    gOwnedLeft := 0
    gOwnedTop := 0
    gOwnedRight := 0
    gOwnedBottom := 0
}


RectMatchesOwnedClip(rect) {
    global gOwnedLeft, gOwnedTop, gOwnedRight, gOwnedBottom

    return rect[1] = gOwnedLeft
        && rect[2] = gOwnedTop
        && rect[3] = gOwnedRight
        && rect[4] = gOwnedBottom
}


RectIsVirtualScreen(rect) {
    global SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN
    global SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN

    left := DllCall(
        "user32\GetSystemMetrics",
        "Int", SM_XVIRTUALSCREEN,
        "Int"
    )
    top := DllCall(
        "user32\GetSystemMetrics",
        "Int", SM_YVIRTUALSCREEN,
        "Int"
    )
    width := DllCall(
        "user32\GetSystemMetrics",
        "Int", SM_CXVIRTUALSCREEN,
        "Int"
    )
    height := DllCall(
        "user32\GetSystemMetrics",
        "Int", SM_CYVIRTUALSCREEN,
        "Int"
    )

    return rect[1] = left
        && rect[2] = top
        && rect[3] = left + width
        && rect[4] = top + height
}


GetCurrentClipRect() {
    rectBuffer := Buffer(16, 0)

    if !DllCall(
        "user32\GetClipCursor",
        "Ptr", rectBuffer.Ptr,
        "Int"
    )
        return 0

    return [
        NumGet(rectBuffer, 0, "Int"),
        NumGet(rectBuffer, 4, "Int"),
        NumGet(rectBuffer, 8, "Int"),
        NumGet(rectBuffer, 12, "Int")
    ]
}


GetCursorMonitorRect() {
    global MONITOR_DEFAULTTONEAREST

    pointBuffer := Buffer(8, 0)
    if !DllCall(
        "user32\GetCursorPos",
        "Ptr", pointBuffer.Ptr,
        "Int"
    )
        return 0

    x := NumGet(pointBuffer, 0, "Int")
    y := NumGet(pointBuffer, 4, "Int")
    packedPoint := (y << 32) | (x & 0xFFFFFFFF)

    monitor := DllCall(
        "user32\MonitorFromPoint",
        "Int64", packedPoint,
        "UInt", MONITOR_DEFAULTTONEAREST,
        "Ptr"
    )
    if !monitor
        return 0

    monitorInfo := Buffer(40, 0)
    NumPut("UInt", monitorInfo.Size, monitorInfo, 0)

    if !DllCall(
        "user32\GetMonitorInfoW",
        "Ptr", monitor,
        "Ptr", monitorInfo.Ptr,
        "Int"
    )
        return 0

    ; Use rcMonitor, the full monitor rectangle. Ignore rcWork.
    return [
        NumGet(monitorInfo, 4, "Int"),
        NumGet(monitorInfo, 8, "Int"),
        NumGet(monitorInfo, 12, "Int"),
        NumGet(monitorInfo, 16, "Int")
    ]
}


RectToBuffer(rect) {
    rectBuffer := Buffer(16, 0)
    NumPut("Int", rect[1], rectBuffer, 0)
    NumPut("Int", rect[2], rectBuffer, 4)
    NumPut("Int", rect[3], rectBuffer, 8)
    NumPut("Int", rect[4], rectBuffer, 12)
    return rectBuffer
}


HandleDisplayChange(*) {
    ; Allow Windows to publish the new monitor topology first.
    SetTimer(RefreshClipAfterDisplayChange, -100)
}


RefreshClipAfterDisplayChange() {
    global gEnabled, gMoveSizeActive, gBoundaryBypass

    Critical("On")

    try {
        if !gEnabled || !gMoveSizeActive || gBoundaryBypass
            return

        ReleaseOwnedClip()
        TryLockToCursorMonitor()
    } catch Error as err {
        DisableAfterError(err)
    }
}


DisableAfterError(err) {
    global APP_NAME, gEnabled, gMoveSizeActive, gMoveSizeWindow

    gEnabled := false
    gMoveSizeActive := false
    gMoveSizeWindow := 0

    try {
        StopGuard()
    }
    try {
        SyncTrayChecks()
    }
    try {
        TrayTip(
            "Monitor confinement was disabled after an unexpected error.",
            APP_NAME
        )
    }
}


CleanupOnUnhandledError(thrownValue, mode) {
    try {
        StopGuard()
    }

    ; Preserve AutoHotkey's normal error reporting after cleanup.
    return false
}


CleanupOnExit(*) {
    global gWinEventHook, gWinEventCallback

    Critical("On")

    try {
        SetTimer(ActiveDragTick, 0)
        SetTimer(RefreshClipAfterDisplayChange, 0)
        ReleaseOwnedClip()
    }

    if gWinEventHook {
        try {
            DllCall(
                "user32\UnhookWinEvent",
                "Ptr", gWinEventHook,
                "Int"
            )
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
