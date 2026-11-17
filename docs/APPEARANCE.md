# Appearance modes

Settings → Appearance has two independent preferences, both off by default:

- **No Liquid Glass** (`appearance.noLiquidGlass`): custom app chrome using classic
  ultra-thin/thin materials. Onboarding keeps its glass design.
- **Spring & unblur motion** (`appearance.springUnblurMotion`): one-shot arrival
  animations for navigation, tabs, sheets, floating control groups and onboarding
  steps. Reduce Motion disables the added blur and displacement. The preview in
  Appearance can replay it without navigating away.

## Adding screens and controls

Use the adaptive components, not raw SwiftUI chrome:

- `AppNavigationStack`, `AppNavigationLink`, `.appNavigationDestination` and
  `.appNavigationTitle` retain the native routing engine. Classic mode hides its
  bars entirely and draws a compact header with its own back button and actions.
- `.appToolbar`, `AppToolbarItem`, `AppToolbarItemGroup` and `@AppToolbarBuilder`
  describe actions once for both renderers. Computed toolbar properties return
  `some AppToolbarContent`, not `some ToolbarContent`.
- `AppMenu`, `.appContextMenu`, `.appConfirmationDialog`, `.appAlert` and
  `.appPopover` draw custom classic popups. Action activation is deferred until
  the popup has dismissed, so actions may safely open another presentation.
- `.appSheet`, `.appPresentationDetents` and `AppPresentationDetent` draw classic
  panels in a transparent fullscreen presentation context, not a system sheet.
  `.appInteractiveDismissDisabled` also guards backdrop and drag dismissal.
- `AppPicker`, `.appPickerStyle`, `AppSlider`, `AppStepper`, `AppColorPicker` and
  `AppDatePicker` replace the corresponding system controls. `AppPicker` reads
  ordinary `.tag` values, including those inside `ForEach`.
- `AppToggleStyle` selects the custom switch automatically.
- `.appGlassEffect`, `.appGlassButtonStyle` and `AppGlassEffectContainer` switch
  existing floating controls between renderers. Pass `frostTint` explicitly for
  tinted material; `Glass` doesn't expose its tint for conversion.

The classic tab bar is **docked, full-width and 64 points tall**, with its
background extending under the home indicator. `AppTabChrome` propagates its
height, and the per-screen chrome reserves that space *inside* the screen's
layout. Do not replace this with padding outside `TabView`: nested forms can
otherwise scroll their final rows behind the dock. Sheets reset that inset to
zero. Bottom toolbars reserve their own space as well.

`FrostedSurface` and `FrostedBackdrop` use opaque surfaces under Reduce
Transparency. New effects should use `AppMotion`, honor Reduce Motion, and be
one-shot or driven by explicit UI state. Do not animate every scrolling row or
replay blur on reading-progress/model updates. `.appReveal(trigger:)` preserves
view identity, navigation and focus; `.appUnblurVisibility` handles reader
controls deliberately kept mounted while hidden.

## Boundaries and validation

These components control **app-owned** UI. iOS-owned document/photo/share
interfaces, authentication interfaces, the keyboard and text-editing menus
remain system UI; this mode does not globally patch UIKit or private views.
The source-verification web view has its own classic header and fullscreen
presentation instead of a system navigation sheet.

A successful build checks compilation and resource membership, not appearance,
hit-testing or interactive presentation behavior on an iPhone. This change has
not been device-verified.
