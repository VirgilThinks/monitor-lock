#Requires AutoHotkey v2.0
#SingleInstance Force

Persistent true

global APP_NAME := "AHK Monitor Lock"

global EVENT_SYSTEM_MOVESIZESTART := 0x000A
global EVENT_SYSTEM_MOVESIZEEND := 0x000B
global WINEVENT_OUTOFCONTEXT := 0x0000
global WINEVENT_SKIPOWNPROCESS := 0x0002
global WM_DISPLAYCHANGE := 0x007E
global WM_MOUSEMOVE := 0x0200
global WH_MOUSE_LL := 14

global VK_LBUTTON := 0x01
global VK_RBUTTON := 0x02
global SM_SWAPBUTTON := 23
global SM_XVIRTUALSCREEN := 76
global SM_YVIRTUALSCREEN := 77
global SM_CXVIRTUALSCREEN := 78
global SM_CYVIRTUALSCREEN := 79
global MONITOR_DEFAULTTONEAREST := 0x00000002
global DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE := -3
global BARRIER_AXIS_X := 1
global BARRIER_AXIS_Y := 2
global CORNER_BARRIER_FRACTION_DENOMINATOR := 5

global gEnabled := true
global gCornerBarriersEnabled := false
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
global gMouseHookCallback := 0
global gMouseHook := 0
global gCornerBarriers := []
global gLastPointerPositionKnown := false
global gLastPointerX := 0
global gLastPointerY := 0
global gCornerBarrierFaulted := false
global gCornerBarrierError := 0
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

    SyncCornerBarrierHook()
}


ConfigureTray() {
    global APP_NAME

    A_TrayMenu.Delete()
    A_TrayMenu.Add("Enabled", ToggleEnabled)
    A_TrayMenu.Add("Corner barriers", ToggleCornerBarriers)
    A_TrayMenu.Add("Start with Windows", ToggleStartup)
    A_TrayMenu.Add()
    A_TrayMenu.Add("Exit", ExitRequested)
    A_TrayMenu.Default := "Enabled"
    A_IconTip := APP_NAME

    SyncTrayChecks()
}


SyncTrayChecks() {
    global gEnabled, gCornerBarriersEnabled

    if gEnabled
        A_TrayMenu.Check("Enabled")
    else
        A_TrayMenu.Uncheck("Enabled")

    if gCornerBarriersEnabled
        A_TrayMenu.Check("Corner barriers")
    else
        A_TrayMenu.Uncheck("Corner barriers")

    if IsStartupEnabled()
        A_TrayMenu.Check("Start with Windows")
    else
        A_TrayMenu.Uncheck("Start with Windows")
}


ToggleEnabled(*) {
    global gEnabled, gMoveSizeActive

    gEnabled := !gEnabled

    try {
        if gEnabled {
            if gMoveSizeActive
                StartGuard()
            SyncCornerBarrierHook()
        } else {
            StopGuard()
            StopCornerBarrierHook()
        }
    } catch Error as err {
        DisableAfterError(err)
    }

    SyncTrayChecks()
}


ToggleCornerBarriers(*) {
    global gCornerBarriersEnabled

    gCornerBarriersEnabled := !gCornerBarriersEnabled

    try {
        SyncCornerBarrierHook()
    } catch Error as err {
        DisableAfterError(err)
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


; Install the low-level hook only while persistent corner barriers are active.
; This keeps normal idle mouse input outside AutoHotkey when the option is off.
SyncCornerBarrierHook() {
    global gEnabled, gCornerBarriersEnabled

    if gEnabled && gCornerBarriersEnabled
        StartCornerBarrierHook()
    else
        StopCornerBarrierHook()
}


; Prepare physical monitor geometry before enabling the event-driven mouse hook.
StartCornerBarrierHook() {
    global WH_MOUSE_LL
    global gMouseHookCallback, gMouseHook
    global gCornerBarrierFaulted, gCornerBarrierError

    if gMouseHook
        return

    RefreshCornerBarriers()

    SeedLastPointerPosition()

    gCornerBarrierFaulted := false
    gCornerBarrierError := 0
    gMouseHookCallback := CallbackCreate(LowLevelMouseProc, , 3)

    moduleHandle := DllCall(
        "kernel32\GetModuleHandleW",
        "Ptr", 0,
        "Ptr"
    )
    gMouseHook := DllCall(
        "user32\SetWindowsHookExW",
        "Int", WH_MOUSE_LL,
        "Ptr", gMouseHookCallback,
        "Ptr", moduleHandle,
        "UInt", 0,
        "Ptr"
    )

    if !gMouseHook {
        errorCode := A_LastError
        CallbackFree(gMouseHookCallback)
        gMouseHookCallback := 0
        throw OSError(errorCode, "SetWindowsHookExW")
    }
}


; Remove the hook before freeing its AutoHotkey callback. If Windows refuses to
; remove it, retain the callback so that no installed hook points at freed code.
StopCornerBarrierHook() {
    global gMouseHookCallback, gMouseHook
    global gLastPointerPositionKnown

    if gMouseHook {
        if !DllCall(
            "user32\UnhookWindowsHookEx",
            "Ptr", gMouseHook,
            "Int"
        )
            return false

        gMouseHook := 0
    }

    if gMouseHookCallback {
        CallbackFree(gMouseHookCallback)
        gMouseHookCallback := 0
    }

    gLastPointerPositionKnown := false
    return true
}


; Build directed barriers in doubled physical-pixel coordinates. Odd boundary
; coordinates lie exactly between the last pixel of one monitor and the next.
RefreshCornerBarriers() {
    global gCornerBarriers

    previousDpiContext := EnterPhysicalCoordinateContext()
    barriers := []

    try {
        monitorCount := MonitorGetCount()
        Loop monitorCount {
            MonitorGet(
                A_Index,
                &left,
                &top,
                &right,
                &bottom
            )
            AddMonitorCornerBarriers(
                barriers,
                left,
                top,
                right,
                bottom
            )
        }
    } finally {
        RestoreCoordinateContext(previousDpiContext)
    }

    gCornerBarriers := barriers
}


; Add two closed 20% segments to every edge. Spans use a shared integer scale
; so percentage endpoints remain exact.
AddMonitorCornerBarriers(barriers, left, top, right, bottom) {
    global BARRIER_AXIS_X, BARRIER_AXIS_Y
    global CORNER_BARRIER_FRACTION_DENOMINATOR

    leftBoundary := 2 * left - 1
    rightBoundary := 2 * right - 1
    topBoundary := 2 * top - 1
    bottomBoundary := 2 * bottom - 1
    width := rightBoundary - leftBoundary
    height := bottomBoundary - topBoundary
    scale := CORNER_BARRIER_FRACTION_DENOMINATOR

    AddBarrier(
        barriers,
        BARRIER_AXIS_X,
        leftBoundary,
        -1,
        left,
        topBoundary * scale,
        topBoundary * scale + height
    )
    AddBarrier(
        barriers,
        BARRIER_AXIS_X,
        leftBoundary,
        -1,
        left,
        bottomBoundary * scale - height,
        bottomBoundary * scale
    )
    AddBarrier(
        barriers,
        BARRIER_AXIS_X,
        rightBoundary,
        1,
        right - 1,
        topBoundary * scale,
        topBoundary * scale + height
    )
    AddBarrier(
        barriers,
        BARRIER_AXIS_X,
        rightBoundary,
        1,
        right - 1,
        bottomBoundary * scale - height,
        bottomBoundary * scale
    )

    AddBarrier(
        barriers,
        BARRIER_AXIS_Y,
        topBoundary,
        -1,
        top,
        leftBoundary * scale,
        leftBoundary * scale + width
    )
    AddBarrier(
        barriers,
        BARRIER_AXIS_Y,
        topBoundary,
        -1,
        top,
        rightBoundary * scale - width,
        rightBoundary * scale
    )
    AddBarrier(
        barriers,
        BARRIER_AXIS_Y,
        bottomBoundary,
        1,
        bottom - 1,
        leftBoundary * scale,
        leftBoundary * scale + width
    )
    AddBarrier(
        barriers,
        BARRIER_AXIS_Y,
        bottomBoundary,
        1,
        bottom - 1,
        rightBoundary * scale - width,
        rightBoundary * scale
    )
}


AddBarrier(
    barriers,
    axis,
    boundary,
    outwardDirection,
    insideCoordinate,
    spanStartScaled,
    spanEndScaled
) {
    barriers.Push({
        axis: axis,
        boundary: boundary,
        outwardDirection: outwardDirection,
        insideCoordinate: insideCoordinate,
        spanStartScaled: spanStartScaled,
        spanEndScaled: spanEndScaled
    })
}


SeedLastPointerPosition() {
    global gLastPointerPositionKnown, gLastPointerX, gLastPointerY

    cursorPosition := GetPhysicalCursorPosition()
    if IsObject(cursorPosition) {
        gLastPointerPositionKnown := true
        gLastPointerX := cursorPosition[1]
        gLastPointerY := cursorPosition[2]
    } else {
        gLastPointerPositionKnown := false
    }
}


; Process only pointer movement. A handled movement is replaced with a clamped
; position and suppressed; all other mouse events continue down the hook chain.
LowLevelMouseProc(nCode, wParam, lParam) {
    global WM_MOUSEMOVE
    global gEnabled, gCornerBarriersEnabled
    global gLastPointerPositionKnown, gLastPointerX, gLastPointerY
    global gCornerBarrierFaulted, gCornerBarrierError

    Critical("On")

    if nCode < 0
        return CallNextMouseHook(nCode, wParam, lParam)

    if wParam != WM_MOUSEMOVE
        return CallNextMouseHook(nCode, wParam, lParam)

    if !gEnabled || !gCornerBarriersEnabled || gCornerBarrierFaulted
        return CallNextMouseHook(nCode, wParam, lParam)

    try {
        proposedX := NumGet(lParam, 0, "Int")
        proposedY := NumGet(lParam, 4, "Int")

        if !gLastPointerPositionKnown {
            gLastPointerPositionKnown := true
            gLastPointerX := proposedX
            gLastPointerY := proposedY
            return CallNextMouseHook(nCode, wParam, lParam)
        }

        constrainedPosition := ConstrainCornerBarrierMovement(
            gLastPointerX,
            gLastPointerY,
            proposedX,
            proposedY
        )

        if !IsObject(constrainedPosition) {
            gLastPointerX := proposedX
            gLastPointerY := proposedY
            return CallNextMouseHook(nCode, wParam, lParam)
        }

        cursorMustMove := constrainedPosition[1] != gLastPointerX
            || constrainedPosition[2] != gLastPointerY

        ; Set the accepted position first so a movement generated by SetCursorPos
        ; cannot be mistaken for another attempted crossing.
        gLastPointerX := constrainedPosition[1]
        gLastPointerY := constrainedPosition[2]
        if cursorMustMove
            SetPhysicalCursorPosition(gLastPointerX, gLastPointerY)
        return 1
    } catch Error as err {
        gCornerBarrierFaulted := true
        gCornerBarrierError := err
        SetTimer(HandleCornerBarrierError, -1)
        return CallNextMouseHook(nCode, wParam, lParam)
    }
}


CallNextMouseHook(nCode, wParam, lParam) {
    global gMouseHook

    return DllCall(
        "user32\CallNextHookEx",
        "Ptr", gMouseHook,
        "Int", nCode,
        "Ptr", wParam,
        "Ptr", lParam,
        "Ptr"
    )
}


; Defer failure handling until after the low-level callback has returned. Hook
; teardown and tray updates are unsafe work for the time-critical callback.
HandleCornerBarrierError() {
    global gCornerBarrierFaulted, gCornerBarrierError

    if !gCornerBarrierFaulted
        return

    if IsObject(gCornerBarrierError)
        errorToReport := gCornerBarrierError
    else
        errorToReport := Error("Corner barrier mouse handling failed.")
    gCornerBarrierFaulted := false
    gCornerBarrierError := 0
    DisableAfterError(errorToReport)
}


; Sweep the proposed movement against every directed barrier. All barriers at
; the earliest collision are resolved together, including both sides of a corner.
ConstrainCornerBarrierMovement(fromX, fromY, proposedX, proposedY) {
    global BARRIER_AXIS_X, BARRIER_AXIS_Y

    collision := FindEarliestBarrierCollision(
        2 * fromX,
        2 * fromY,
        2 * proposedX,
        2 * proposedY
    )
    if !IsObject(collision)
        return 0

    constrainedX := proposedX
    constrainedY := proposedY
    blocksX := false
    blocksY := false

    for candidate in collision.candidates {
        barrier := candidate.barrier
        if barrier.axis = BARRIER_AXIS_X {
            blocksX := true
            constrainedX := barrier.insideCoordinate
            collisionXBoundary := barrier.boundary
            collisionYNumber := candidate.tangentNumber
            collisionYDenominator := candidate.tangentDenominator
        } else if barrier.axis = BARRIER_AXIS_Y {
            blocksY := true
            constrainedY := barrier.insideCoordinate
            collisionYBoundary := barrier.boundary
            collisionXNumber := candidate.tangentNumber
            collisionXDenominator := candidate.tangentDenominator
        }
    }

    ; After the first collision, sweep any remaining tangential movement. This
    ; allows sliding while still detecting a second barrier reached at a corner.
    if blocksX && !blocksY {
        slideCollision := FindEarliestBarrierCollisionOnSlide(
            BARRIER_AXIS_Y,
            collisionXBoundary,
            collisionYNumber,
            collisionYDenominator,
            2 * proposedY
        )
        if IsObject(slideCollision) {
            blocksY := true
            constrainedY := slideCollision.candidates[1].barrier.insideCoordinate
        }
    } else if blocksY && !blocksX {
        slideCollision := FindEarliestBarrierCollisionOnSlide(
            BARRIER_AXIS_X,
            collisionYBoundary,
            collisionXNumber,
            collisionXDenominator,
            2 * proposedX
        )
        if IsObject(slideCollision) {
            blocksX := true
            constrainedX := slideCollision.candidates[1].barrier.insideCoordinate
        }
    }

    return [constrainedX, constrainedY]
}


; Find all barriers reached at the earliest exact rational time on a movement.
FindEarliestBarrierCollision(fromX, fromY, toX, toY) {
    global BARRIER_AXIS_X, BARRIER_AXIS_Y, gCornerBarriers

    earliestCandidates := []
    earliestTimeNumber := 0
    earliestTimeDenominator := 1

    for barrier in gCornerBarriers {
        if barrier.axis = BARRIER_AXIS_X {
            candidate := GetBarrierCollision(
                barrier,
                fromX,
                toX,
                fromY,
                toY
            )
        } else if barrier.axis = BARRIER_AXIS_Y {
            candidate := GetBarrierCollision(
                barrier,
                fromY,
                toY,
                fromX,
                toX
            )
        } else {
            continue
        }

        if !IsObject(candidate)
            continue

        if earliestCandidates.Length = 0
            || FractionIsLess(
                candidate.timeNumber,
                candidate.timeDenominator,
                earliestTimeNumber,
                earliestTimeDenominator
            ) {
            earliestCandidates := [candidate]
            earliestTimeNumber := candidate.timeNumber
            earliestTimeDenominator := candidate.timeDenominator
        } else if FractionsAreEqual(
            candidate.timeNumber,
            candidate.timeDenominator,
            earliestTimeNumber,
            earliestTimeDenominator
        ) {
            earliestCandidates.Push(candidate)
        }
    }

    if earliestCandidates.Length = 0
        return 0

    return {
        candidates: earliestCandidates,
        timeNumber: earliestTimeNumber,
        timeDenominator: earliestTimeDenominator
    }
}


; Return a collision only when movement goes from a barrier's permitted side to
; its forbidden side and the exact crossing lies on the closed barrier segment.
GetBarrierCollision(
    barrier,
    fromNormal,
    toNormal,
    fromTangent,
    toTangent
) {
    fromDistance := barrier.outwardDirection
        * (fromNormal - barrier.boundary)
    toDistance := barrier.outwardDirection
        * (toNormal - barrier.boundary)

    if fromDistance > 0 || toDistance <= 0
        return 0

    timeNumber := barrier.boundary - fromNormal
    timeDenominator := toNormal - fromNormal
    if timeDenominator < 0 {
        timeNumber := -timeNumber
        timeDenominator := -timeDenominator
    }

    if timeNumber < 0 || timeNumber > timeDenominator
        return 0

    tangentNumber := fromTangent * timeDenominator
        + (toTangent - fromTangent) * timeNumber
    if !BarrierContainsRationalPosition(
        barrier,
        tangentNumber,
        timeDenominator
    )
        return 0

    return {
        barrier: barrier,
        timeNumber: timeNumber,
        timeDenominator: timeDenominator,
        tangentNumber: tangentNumber,
        tangentDenominator: timeDenominator
    }
}


; A first collision leaves movement along one axis. Sweep that exact rational
; segment so sliding into another barrier is resolved in the same input update.
FindEarliestBarrierCollisionOnSlide(
    barrierAxis,
    fixedTangent,
    fromNormalNumber,
    fromNormalDenominator,
    toNormal
) {
    global gCornerBarriers

    earliestCandidates := []
    earliestTimeNumber := 0
    earliestTimeDenominator := 1

    for barrier in gCornerBarriers {
        if barrier.axis != barrierAxis
            continue

        if !BarrierContainsRationalPosition(barrier, fixedTangent, 1)
            continue

        fromDistanceNumber := barrier.outwardDirection
            * (
                fromNormalNumber
                - barrier.boundary * fromNormalDenominator
            )
        toDistance := barrier.outwardDirection
            * (toNormal - barrier.boundary)
        if fromDistanceNumber > 0 || toDistance <= 0
            continue

        timeNumber := barrier.boundary * fromNormalDenominator
            - fromNormalNumber
        timeDenominator := toNormal * fromNormalDenominator
            - fromNormalNumber
        if timeDenominator < 0 {
            timeNumber := -timeNumber
            timeDenominator := -timeDenominator
        }

        if timeNumber < 0 || timeNumber > timeDenominator
            continue

        candidate := {
            barrier: barrier,
            timeNumber: timeNumber,
            timeDenominator: timeDenominator
        }
        if earliestCandidates.Length = 0
            || FractionIsLess(
                timeNumber,
                timeDenominator,
                earliestTimeNumber,
                earliestTimeDenominator
            ) {
            earliestCandidates := [candidate]
            earliestTimeNumber := timeNumber
            earliestTimeDenominator := timeDenominator
        } else if FractionsAreEqual(
            timeNumber,
            timeDenominator,
            earliestTimeNumber,
            earliestTimeDenominator
        ) {
            earliestCandidates.Push(candidate)
        }
    }

    if earliestCandidates.Length = 0
        return 0

    return {
        candidates: earliestCandidates,
        timeNumber: earliestTimeNumber,
        timeDenominator: earliestTimeDenominator
    }
}


BarrierContainsRationalPosition(barrier, positionNumber, positionDenominator) {
    global CORNER_BARRIER_FRACTION_DENOMINATOR

    scale := CORNER_BARRIER_FRACTION_DENOMINATOR
    scaledPosition := positionNumber * scale
    return scaledPosition >= barrier.spanStartScaled * positionDenominator
        && scaledPosition <= barrier.spanEndScaled * positionDenominator
}


FractionIsLess(leftNumber, leftDenominator, rightNumber, rightDenominator) {
    return leftNumber * rightDenominator
        < rightNumber * leftDenominator
}


FractionsAreEqual(leftNumber, leftDenominator, rightNumber, rightDenominator) {
    return leftNumber * rightDenominator
        = rightNumber * leftDenominator
}


GetPhysicalCursorPosition() {
    previousDpiContext := EnterPhysicalCoordinateContext()
    pointBuffer := Buffer(8, 0)

    try {
        if !DllCall(
            "user32\GetCursorPos",
            "Ptr", pointBuffer.Ptr,
            "Int"
        )
            return 0

        return [
            NumGet(pointBuffer, 0, "Int"),
            NumGet(pointBuffer, 4, "Int")
        ]
    } finally {
        RestoreCoordinateContext(previousDpiContext)
    }
}


SetPhysicalCursorPosition(x, y) {
    previousDpiContext := EnterPhysicalCoordinateContext()

    try {
        succeeded := DllCall(
            "user32\SetCursorPos",
            "Int", x,
            "Int", y,
            "Int"
        )
        errorCode := A_LastError
    } finally {
        RestoreCoordinateContext(previousDpiContext)
    }

    if !succeeded
        throw OSError(errorCode, "SetCursorPos")
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
    SetTimer(RefreshAfterDisplayChange, -100)
}


RefreshAfterDisplayChange() {
    global gEnabled, gMoveSizeActive, gBoundaryBypass, gMouseHook

    Critical("On")

    try {
        if gMouseHook {
            RefreshCornerBarriers()
            SeedLastPointerPosition()
        }

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
        StopCornerBarrierHook()
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
    try {
        StopCornerBarrierHook()
    }

    ; Preserve AutoHotkey's normal error reporting after cleanup.
    return false
}


CleanupOnExit(*) {
    global gWinEventHook, gWinEventCallback

    Critical("On")

    try {
        SetTimer(ActiveDragTick, 0)
        SetTimer(RefreshAfterDisplayChange, 0)
        ReleaseOwnedClip()
        StopCornerBarrierHook()
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
