# Entry detail screen layout

How `EntryDetailView` (novels and manga) places its controls, and where a new one goes.

## What was wrong

Controls were added wherever there was room, so the screen had no rules:

- Tracking appeared twice: a toolbar icon and a labelled row between the summary and chapters.
- Author and status were shown in the hero, then again in a metadata grid.
- "Last fetched / Refresh" was a loose row of grey text with a borderless button.
- The chapter header carried four glass circles (search, filter, scanlators, downloads), two of
  which act on the whole entry, not on the list.
- Audio downloads was a toolbar icon on novels only, with no label.
- A new entry action (migrate, edit info, categories) had nowhere to go.

## The rule: a control lives with what it acts on

| Zone | Holds | Limit |
|---|---|---|
| **Hero** | Title, byline (author · artist), status · source, the one primary action (Start/Continue) | Exactly one prominent button |
| **Action bar** (`EntryActionBar`) | Entry actions that carry state: Library, Tracking, Downloads, Audio. Plain glass buttons in the hero, in the same `GlassEffectContainer` as the primary button | Four |
| **Toolbar** | One `…` menu: Change cover, Migrate, Open in web view, Share link, Refresh | One menu |
| **About** (`EntryInfoSection`) | Summary and genres. Nothing tappable except "Show more" | — |
| **Chapter header** | Controls for the list only: search, and one sort/filter menu (order, filter, scanlators) | Two buttons |

Consequences:

- **Tracking has one home**: the tracking tile. Its label is the AniList status ("Reading") once
  bound, so the summary the old row gave is still visible.
- **Downloads** moved from the chapter header to a tile; it queues chapters for the entry.
- **Scanlators** moved into the sort/filter menu, and only appears when the list has scanlators.
- **The toolbar is one `…` menu.** Change cover, Migrate, Open in web view, Share link and
  Refresh live there; five separate buttons crowded the bar. Refresh is still not pull to
  refresh, because pulling down dismisses the screen, and while it runs the status under the
  chapter count says "Refreshing…".
- **Migrate** is in that menu (`migrateButton`, library entries from sources only), at the top
  beside Change cover. It was briefly the only item of a `…` menu, which hid the one action
  you go looking for when a source breaks — the menu now holds several, so it earns its place.
- **Action buttons are glass over the hero**, not cards in the content below it. State shows in
  the symbol (filled when on), never as an outline or a different fill, so no secondary action
  competes with the primary button.
- The metadata grid is gone; its facts are the hero's byline and status line.

## Adding an action

1. Does it show state the user should see at a glance (on/off, a status)? Make it a tile in
   `EntryActionBar`, if fewer than four are showing for that kind. Otherwise:
2. Add it to the `…` menu in `EntryDetailView` (`moreMenu`). **Migrate** (`migrateButton`,
   library entries from sources only) is there today. The menu earns its place because it
   holds several actions; do not put a single action in a `…` menu.
3. If it acts on chapters, it belongs to the chapter header's menu, not to either of the above.

Tiles per kind today: novel in library 4 (Library, Tracking, Download, Audio), manga in library 3,
browse result 1–2 (Library, Audio). Nothing that needs a library entry shows before it is added.
