# Notch panel is always visible: in fullscreen spaces, on any screen layout

The notch panel (agent list / approval surface) must be visible in every state
the user works in: normal spaces, fullscreen spaces, and any screen layout
(docked external displays, or the built-in notch display alone). The previous
behaviour hid the panel while a fullscreen app was frontmost and restored it
on the next space-change notification; when that notification never fired the
panel stayed offscreen indefinitely, which read as "the agent list is gone"
(2026-10-11). The `handleSpaceChange` / `isActiveSpaceFullscreen` hiding logic
is removed; the panel's `.fullScreenAuxiliary` collectionBehavior (already
present) is what permits floating above fullscreen spaces. The collapsed bar
occupies notch-width only, so the fullscreen occlusion cost is minimal.

## Screen choice

When an external display is docked, the panel stays on the built-in notch
display (`ScreenDetector.preferredScreen` prefers a screen with a physical
notch). The user works mostly on the external display, so the panel then sits
in peripheral vision rather than under the eye — accepted for now.

**Recorded alternative (not implemented, candidate if that changes):** follow
the focused screen (`NSScreen.main`) so the panel is always on the screen the
user is working on, polling the 1s timer for main-screen changes, showing the
simulated-notch bar shape on displays without a physical notch. Revisit if
"docked but looking at the external display" turns out to hide the panel too
much.

## Consequences

Approval pop-ups and the working/idle counts are visible during fullscreen
terminal work — that is the point. Screen dock/undock transitions must
re-anchor the panel (`handleScreenChange` re-positions and re-orders front)
so a layout change can never leave it offscreen again.
