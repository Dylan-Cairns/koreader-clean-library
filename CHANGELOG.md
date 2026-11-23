# Changelog

## 0.1.1

- History and Collections rows keep the file browser's height when a plugin
  hides the page-info footer without removing it from the menu: a detached
  footer no longer reserves height. This fixes the shorter rows seen with
  Visual Overhaul Suite's "hide pagination" (229 px vs 244 px on a BOOX Go 6;
  both are 244 px now).
- README: documented the interaction with Visual Overhaul Suite (row height,
  title underscore replacement and title bar).

## 0.1.0

- Initial plugin release, extracted from a working user patch.
- Uniform 2:3 cover cells with an inset gap, rounded corners, rounded border,
  and a 45% stretch allowance for covers close to 2:3.
- Hides CoverBrowser's "book was opened" dogear in list rows.
- Generic full-bleed placeholder cover for books without cover art, shipped
  inside the plugin.
- PDFs whose page-1 thumbnail is a text page use the placeholder cover.
- Replaces underscores with spaces in list titles.
- Fixes list rows staying stock when History is opened before the file
  browser: the row class is now hooked from `Menu:switchItemTable`, which
  `BookList` (History, Collections) uses, not only from `FileChooser`.
- The file manager's first page is refreshed once plugin startup completes,
  because plugins load after that page has already been built.
