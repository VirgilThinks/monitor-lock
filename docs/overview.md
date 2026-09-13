# Monitor Lock

Monitor Lock keeps the mouse pointer on its current monitor while you move or resize a window. It prevents accidental jumps to another display without changing how Windows arranges your monitors.

It runs quietly in the Windows system tray and supports both standard and swapped mouse buttons.

It is an AutoHotkey script.

Development will remain focused on the AutoHotkey script for now. We may also explore a simple, independent Windows programme if there is a good reason to move beyond AutoHotkey, and may maintain both routes in parallel if each proves useful.

The AutoHotkey proof of concept provides a toggleable [Corner barriers](planned/barriers.md) option. Its persistent, unidirectional barriers use event-driven mouse handling rather than continuously polling the pointer position.
