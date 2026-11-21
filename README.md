# Clean Library

A KOReader plugin that makes CoverBrowser's **detailed list** rows consistent:
one cover width for every book, a small inset, rounded corners and no badges.
Books with no cover art get a generic cover so the list never falls back to a
dotted square or a scanned page of text.

Built for e-ink; no colour is required.

## What it changes

List rows in the file manager, History and Collections:

- **Uniform cells.** Every thumbnail is drawn in a fixed 2:3 cell, so covers
  line up regardless of the source image's aspect ratio. Covers within 45% of
  2:3 are stretched mildly to fill; anything further off is fitted and
  letterboxed rather than distorted. The cell is inset from the row edges and
  has rounded corners and a thin rounded border.
- **No dogear.** The "book was opened" corner mark is hidden.
- **Placeholder covers.** A book without cover art gets a full-bleed generic
  cover instead of CoverBrowser's dotted-square placeholder.
- **PDF text pages.** PDFs have no embedded cover, so KOReader uses page 1.
  When that page is mostly blank paper (85%+ of a coarse sample is light), the
  row shows the generic cover instead of a washed-out scan. A PDF whose first
  page is real cover art keeps it.
- **Underscores.** `my_book_title.md` is listed as `my book title` (matching
  the cleanup many UI plugins apply to menu items).

Mosaic view, cover view, the reader, and classic (non-CoverBrowser) menus are
not modified.

## Install

1. Copy the `cleanlibrary.koplugin` directory into `koreader/plugins/` on your
   device. The result is `koreader/plugins/cleanlibrary.koplugin/main.lua`.
2. Restart KOReader.

The placeholder artwork lives inside the plugin
(`cleanlibrary.koplugin/icons/book_placeholder.svg`), so there is no separate
asset to install.

If you previously used the standalone user patch (`koreader/patches/*clean-library*.lua`),
delete it — otherwise both will try to style the same rows.

## Knobs

At the top of `cleanlibrary.koplugin/main.lua`:

| Constant | Default | Meaning |
| --- | --- | --- |
| `RADIUS` | `scaleBySize(8)` | cover corner radius |
| `GAP` | `scaleBySize(6)` | space between the cell and the row edge |
| `ASPECT` | `2 / 3` | cell aspect ratio |
| `STRETCH_LIMIT` | `45` | maximum % aspect divergence still stretched |
| `BORDER` | `scaleBySize(1)` | border width |
| `TEXT_PAGE_LIGHT` | `0.85` | light-pixel fraction that marks a PDF page as text |
| `REPLACE_UNDERSCORES` | `true` | turn `_` into spaces in list titles |

Edit the SVG and restart to change the placeholder cover.

## Compatibility

Tested with **KOReader v2026.07.2** on a BOOX Go 6 (Android), with source
inspection against v2026.07.1. It needs CoverBrowser in a list display mode
(`list_image_meta`, `list_image_filename` or `list_only_meta`).

CoverBrowser does not expose its list row class: it is a module-local in
`listmenu.lua`, reached through `userpatch.getUpValue`. That is normal for
KOReader UI plugins, but it is private surface, so a KOReader upgrade can break
it. When the class cannot be found the plugin logs
`CleanLibrary: CoverBrowser list view not found; rows left unchanged` and leaves
the UI stock instead of failing. Please re-test the file manager, History,
Collections and PDF rows after upgrading KOReader.

## How it works

- `ListMenuItem:update` (CoverBrowser's row builder) is wrapped once. The
  wrapper cleans the title, hides the dogear, and replaces the thumbnail
  container with the 2:3 cell. The class is found through the upvalue of the
  list builder on `FileChooser`, or of a specific menu instance.
- The hook is installed from `Menu:switchItemTable`, which `BookList` inherits,
  and from `FileChooser:init` / `refreshPath`. History and Collections build
  their rows through `BookList` without touching `FileChooser`, so hooking only
  the file chooser left them stock when they were opened first.
- Rounded corners follow ZenOS's OPDS cover code: mask the corner pixels with
  the background sampled outside the cell, then paint the anti-aliased border
  on top, so the border arcs are not cut away.
- Thumbnails are rendered eagerly (`content:getSize()`) inside `update`, the
  way stock CoverBrowser does it. Deferring the render to paint time lets the
  shared cover buffer be reused by the next row and attaches covers to the
  wrong books.

## Credits

- [KOReader](https://github.com/koreader/koreader) and its CoverBrowser plugin
  (AGPL-3.0): the widget APIs and the list view this hooks into.
- [ZenOS](https://github.com/zenixlabs/zenos.koplugin) 4.3.2 (GPL-3.0): the
  uniform 2:3 cell and radius (`common/cover_utils.lua`,
  `modules/filebrowser/patches/browser_list_item_layout.lua`) and the
  corner-mask-then-border technique
  (`modules/global/patches/opds_browser.lua`). The implementation here is
  rewritten for this plugin, but the approach and the numbers come from ZenOS.

This repository has no licence file, by the author's choice.
