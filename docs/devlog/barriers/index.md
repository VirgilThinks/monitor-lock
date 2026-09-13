# Persistent corner barriers

Implement an AutoHotkey proof of concept which prevents the pointer from leaving any monitor through the first or last 10% of each edge.


## Scope

* Add a toggleable **Corner barriers** tray option.
* Apply corner barriers persistently whenever Monitor Lock and the option are enabled.
* Make barriers unidirectional and independent of move/resize bypass mode.
* Handle pointer movement through an event-driven low-level mouse hook rather than a polling timer.
* Preserve the existing whole-monitor move/resize confinement.


## Stages

* **AutoHotkey proof of concept - in progress.** Implementation is complete and awaiting runtime validation.
* **Validation - pending.** Exercise the behaviour across monitor arrangements, display changes and high-rate pointer input.


## Key decisions and findings

* Each monitor has two barrier segments at each corner, one covering 10% of each meeting edge.
* Barriers prevent leaving their owning monitor, but do not prevent entering it.
* Persistent barriers cannot be bypassed. The top-level **Enabled** option still controls the application as a whole.
* A colliding pointer update loses its perpendicular component and retains its parallel component. Crossing beyond an endpoint requires a subsequent update.
* The low-level hook must do bounded work and use cached monitor rectangles.
* **Corner barriers** is off by default and must be enabled from the tray.
* The hook is installed only while both Monitor Lock and **Corner barriers** are enabled.
