# Appearance modes

Settings → Appearance has two independent preferences, both off by default:

- **No Liquid Glass** (`appearance.noLiquidGlass`): custom app chrome using classic
  ultra-thin/thin materials. Onboarding keeps its glass design.
- **Spring & unblur motion** (`appearance.springUnblurMotion`): motion for custom
  popups, explicitly revealed controls, onboarding steps and switching library
  modes. Never layer it over tab switches, navigation pushes/pops, native sheets
  or the reader's native fullscreen transition. Reduce Motion disables added
  blur and displacement. The Appearance preview plays only when tapped.

## Adding screens and controls

Use the adaptive components, not raw SwiftUI chrome:

- `AppNavigationStack`, `AppNavigationLink`, `.appNavigationDestination` and
  `.appNavigationTitle` retain the native routing engine. Classic mode hides its
  bars entirely and draws a compact header with its own back button and actions.
- `.appToolbar`, `AppToolbarItem`, `AppToolbarItemGroup` and `@AppToolbarBuilder`
  describe actions once for both renderers. Computed toolbar properties return
  `some AppToolbarContent`, not `some ToolbarContent`. Keep one `.appToolbar`
  per screen: the classic renderer places its typed actions directly in safe-area
  insets, rather than collecting views through preferences. Secondary labels are
  icon-only; confirmation actions use blue, compact buttons.
- `AppMenu`, `.appContextMenu`, `.appConfirmationDialog`, `.appAlert` and
  `.appPopover` draw custom classic popups. Action activation is deferred until
  the popup has dismissed, so actions may safely open another presentation.
- `.appSheet`, `.appPresentationDetents` and `AppPresentationDetent` use iOS's
  native sheet presentation in **both** modes; the custom full-screen panel is
  gone. The presentation background is always ours — `Material.ultraThin`, or
  an opaque surface under Reduce Transparency — so system glass never shows.
  Dismissal is controlled by `.appInteractiveDismissDisabled`; our serif title,
  buttons, detents, corner radius and content stay unchanged. Deferred popup
  actions still run only after the sheet is gone.
  `.appInteractiveDismissDisabled` also guards backdrop and drag dismissal.
  Classic panels spring-pop and unblur on opening (when enabled), then reverse
  on closing. The host stays alive until that exit finishes; item-backed sheets
  retain their item during the exit. Use `@Environment(\.appDismiss)` in sheet
  screens so Done/Close uses that exit too; a pushed destination still pops.
  Dragging the handle/header moves a fixed-height panel instead of reflowing its
  contents. Detent selection survives preference updates.
- `AppPicker`, `.appPickerStyle`, `AppSlider`, `AppStepper`, `AppColorPicker` and
  `AppDatePicker` replace the corresponding system controls. `AppPicker` reads
  ordinary `.tag` values, including those inside `ForEach`.
- `AppToggleStyle` selects the custom switch automatically; its thumb animates
  an offset on a fixed track, including when the binding changes externally.
- `AppForm` renders shared grouped settings cards in full screens and sheets,
  including More and the Browse catalogue's source list. Its structure stays
  stable when the material setting changes. Keep long result lists and
  editable/reorderable lists as `List`.
- **Beta — Use iOS default forms** (`appearance.systemForms`, offered only
  while No Liquid Glass is on): `AppForm` hands its `Section` content to a
  native grouped `Form`, so every screen that uses `AppForm` — settings,
  option sheets, filters, trackers, migration, Browse, reader and manga
  settings — switches at once. Titles, buttons and row content stay ours;
  insets, separators, section chrome and row backgrounds come from iOS. This
  does not affect screens that already use a native `List`.
- `.appRefreshable` draws the shared pull indicator on Library, Updates,
  History and other refreshable screens. The indicator is an overlay: it never
  pins a screen or changes its insets while an update publishes store changes.
- Press feedback comes from each control's native `ButtonStyle.isPressed`.
  Never attach a gesture recognizer just to observe a touch: it competes with
  the enclosing `ScrollView`'s pan and makes form rows unscrollable. Scrolling
  and press feedback are not mutually exclusive, and Reduce Motion disables
  the scale. The classic toggle scales only its knob while held, then springs
  back to full size as it travels to the new position.
- Every text input and search bar, including the custom classic search field,
  dismisses the keyboard when the user taps anywhere that is not a text field.
  `.appKeyboardDismissOnTap()` installs a non-cancelling window recognizer once
  at the app root, so it also covers fields inside custom forms and sheets.
  `AppForm` additionally dismisses on scroll.
- `.appGlassEffect`, `.appGlassButtonStyle` and `AppGlassEffectContainer` switch
  existing floating controls between renderers. Pass `frostTint` explicitly for
  tinted material; `Glass` doesn't expose its tint for conversion.

The classic tab bar is **docked, full-width and 64 points tall**, with its
background extending under the home indicator. `AppTabChrome` propagates its
height, and the per-screen chrome reserves that space *inside* the screen's
layout. Do not replace this with padding outside `TabView`: nested forms can
otherwise scroll their final rows behind the dock. Sheets reset that inset to
zero. Bottom toolbars reserve their own space as well. Classic tabs, segmented
pickers, category pills and display choices use primary selected text/icons and
dim unselected ones, without a moving or filled selection highlight. Browse's
Light Novels / Manga selector is an explicit exception: it keeps its grey sliding
capsule in classic mode. Both catalogue selectors use non-interactive Liquid
Glass in glass mode. Library's All / Novel / Manga selector is pinned below the
navigation header; Browse keeps its selector directly below Search, above the
`AppForm` source cards.

The classic page title is left-aligned serif text across all non-glass views.
Its backdrop is clear at the top of a page and fades in after
scrolling eight points; this changes only the backdrop opacity, never blurring
the page itself. `.appNavigationTitle` forwards
its optional vertical-swipe callback to the actual custom title, not just the
hidden native bar. Library accepts either vertical direction to switch modes;
the root mode transition supplies the matching arrival and departure blur/move.

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
