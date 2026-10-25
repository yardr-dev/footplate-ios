import SwiftUI

// Copied from yardr-design/tokens/colors.css. Asset appearances follow the system.
enum ThemeColor: String, CaseIterable {
    case buttonPrimary = "button-primary"
    case buttonPrimaryHover = "button-primary-hover"
    case buttonPrimaryPressed = "button-primary-pressed"
    case surfaceApp = "surface-app"
    case surfaceSunken = "surface-sunken"
    case surfaceRaised = "surface-raised"
    case surfaceHover = "surface-hover"
    case surfacePressed = "surface-pressed"
    case surfacePopover = "surface-popover"
    case borderSubtle = "border-subtle"
    case borderStrong = "border-strong"
    case borderHover = "border-hover"
    case textPrimary = "text-primary"
    case textSecondary = "text-secondary"
    case textDisabled = "text-disabled"
    case textOnAccent = "text-on-accent"
    case textAccent = "text-accent"
    case textError = "text-error"
    case accent = "accent"
    case accentHover = "accent-hover"
    case accentPressed = "accent-pressed"
    case focusRing = "focus-ring"
    case switchOff = "switch-off"
    case switchOffHover = "switch-off-hover"
    case switchThumb = "switch-thumb"
    case statusRunning = "status-running"
    case statusStopped = "status-stopped"
    case statusError = "status-error"

    var color: Color { Color(rawValue) }
}
