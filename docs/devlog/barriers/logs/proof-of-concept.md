# AutoHotkey proof of concept


## Goal

Add persistent corner barriers to the existing AutoHotkey tray utility without introducing continuous pointer polling.


## Work

* Added tray state and low-level mouse-hook lifecycle management.
* Physical monitor rectangles are cached and refreshed after display changes.
* Added path-intersection detection for corner sections of the source monitor's edges.
* Blocked movements are suppressed and replaced with a position which preserves sliding along the barrier.
* Hook resources are released during disablement, errors and exit.


## Status

Implementation is complete. Runtime validation remains outstanding.

Static inspection confirms that tray toggles, hook lifecycle, display refresh, source-monitor collision handling and deferred callback error handling are connected. Behaviour on a live multi-monitor desktop remains unverified.


## Completion criteria

* **Corner barriers** can be toggled from the tray.
* Enabled corner barriers operate outside window move/resize actions and cannot be bypassed.
* Leaving a monitor through an unguarded middle edge remains possible.
* Large diagonal pointer updates cannot jump through guarded corner sections.
* Display changes refresh the active monitor geometry.
* Existing move/resize confinement remains intact.
