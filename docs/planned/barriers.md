# Barriers

A barrier is a hard wall on an edge of a particular monitor. It prevents the mouse pointer from leaving that monitor through the covered part of the edge.

A barrier does not need to occupy the full width or height of the edge. For instance, it could cover the middle 50% of a left or right edge, the bottom 100 pixels, or any other one-dimensional section.


## Geometry

A barrier is defined by its monitor, an explicit monitor edge, a start point and a signed length. The start point uses coordinates local to its monitor, with `(0, 0)` at the monitor's top-left corner.

The start point coordinates and the length can each use either pixels or percentages independently, so a single barrier can mix the two units. Percentage values are relative to the applicable dimension of the monitor.

The length follows the coordinate direction of the edge. A positive length extends rightwards on a horizontal edge or downwards on a vertical edge; a negative length extends in the opposite direction.

A barrier can extend beyond the current monitor edge. Only the intersection between the barrier and the current edge has an effect. The rest remains defined and can become effective following a resolution or monitor-layout change.

A barrier which starts at `0` and extends in the negative direction is invalid. A barrier which starts at `100%` and extends in the positive direction is also invalid.


## Direction

Barriers are unidirectional by default: they prevent the pointer from leaving their monitor, but do not prevent the pointer from entering it. A barrier can be configured as bidirectional, in which case its covered section also prevents the pointer from entering the monitor.

The monitor layout determines which barriers a pointer movement encounters. Multiple barriers can cover the same crossing and stack: the movement is blocked if any applicable barrier blocks it in that direction.


## Pointer movement

When movement meets a barrier, the pointer stops at the barrier in the perpendicular direction but remains free to slide along it.

Collision detection must consider the path between the pointer's previous and proposed positions, rather than only the proposed position. This prevents a sufficiently large or fast movement from jumping across a barrier.

Both endpoints of a barrier are included. This prevents a gap between adjacent barrier segments.

A diagonal movement can encounter a barrier and also travel beyond one of its endpoints in the same pointer update. Its perpendicular component remains blocked for the whole update, while its parallel component can slide beyond the endpoint. A subsequent pointer update can cross the edge beyond the barrier.


## Persistence and bypass

Barriers can be persistent or non-persistent:

* A persistent barrier applies at all times and cannot be bypassed.
* A non-persistent barrier applies only while a window is being moved or resized. It can be bypassed using the normal toggleable bypass mode.

Where persistent and non-persistent barriers overlap, the persistent barrier continues to apply while bypass mode is active.


## AutoHotkey proof of concept

The AutoHotkey proof of concept does not provide individual barrier configuration. It instead provides a toggleable **Corner barriers** option.

When enabled, every monitor receives two barrier segments at each of its four corners: one segment extends from the corner along each of the two edges which meet there, covering 10% of that edge. These barriers prevent the pointer from leaving their owning monitor.

Corner barriers are persistent and unidirectional. They apply whenever Monitor Lock and the option are enabled, including outside window move or resize operations, and cannot be disabled temporarily using bypass mode.

The proof of concept uses event-driven mouse handling rather than continuously polling the pointer position.
