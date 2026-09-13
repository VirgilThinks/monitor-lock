# AutoHotkey proof of concept


## Goal

Add persistent corner barriers to the existing AutoHotkey tray utility without introducing continuous pointer polling.


## Work

* Added tray state and low-level mouse-hook lifecycle management.
* A global directed barrier list is cached and refreshed after display changes.
* Added exact swept-segment intersection using doubled integer coordinates and rational comparisons.
* All barriers reached at the earliest collision are combined, and remaining slide movement is checked for another collision.
* Blocked movements are suppressed and replaced with a position which preserves permitted sliding along the barrier.
* Repeated blocked events which leave the pointer unchanged no longer call `SetCursorPos`.
* Hook resources are released during disablement, errors and exit.


## Status

Implementation is complete. Runtime validation remains outstanding.

Static inspection confirms that tray toggles, hook lifecycle, display refresh, global collision handling and deferred callback error handling are connected. The reported exact-corner tunnelling case now produces simultaneous collisions with both adjacent barriers by construction. Behaviour on a live multi-monitor desktop remains unverified.


## Completion criteria

* **Corner barriers** can be toggled from the tray.
* Enabled corner barriers operate outside window move/resize actions and cannot be bypassed.
* Leaving a monitor through an unguarded middle edge remains possible.
* Large diagonal pointer updates cannot jump through guarded corner sections.
* Display changes refresh the active monitor geometry.
* Existing move/resize confinement remains intact.
