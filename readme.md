# Monitor Lock

Monitor Lock keeps the mouse pointer on its current monitor while you move or resize a window. It prevents accidental jumps to another display without changing how Windows arranges your monitors.

It runs quietly in the Windows system tray and supports both standard and swapped mouse buttons.


## Requirements

* Windows
* [AutoHotkey v2](https://www.autohotkey.com/)


## Install

1. Download or clone this repository.
2. Install AutoHotkey v2 if it is not already installed.
3. Run `monitor-lock.ahk`.

Monitor Lock is enabled as soon as it starts. To run it automatically after signing in, right-click its tray icon and select **Start with Windows**.


## Use

Move or resize a window normally. While the drag is active, the pointer stays within the monitor where the drag began.

To cross into another monitor during a drag, press the secondary mouse button while continuing to hold the primary button. Press it again to restore the boundary.

Right-click the tray icon to:

* enable or disable Monitor Lock;
* turn **Start with Windows** on or off;
* exit the application.


## Troubleshooting

If the pointer is not confined, check that **Enabled** is ticked in the tray menu. Monitor Lock also leaves an existing pointer restriction from another application unchanged.

If Monitor Lock encounters an unexpected error, it disables itself and shows a Windows notification. Restart `monitor-lock.ahk` to try again.
