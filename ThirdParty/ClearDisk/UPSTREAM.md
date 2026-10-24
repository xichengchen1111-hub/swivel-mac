# ClearDisk cache catalogue

This folder holds data taken from ClearDisk, used only by Mac Doctor:

- Repository: https://github.com/bysiber/cleardisk
- Revision: `fb5429c4f8a2ee37340840150153a08e074fdff8` (2026-09-10)
- License: MIT, Copyright (c) 2026 Kadir Can Ozden (`LICENSE`, copied unchanged)

## What was taken

`ClearDiskCatalog.swift` is a plain data table. It holds no ClearDisk code. 46 of ClearDisk's entries were taken, and every one is marked `safe` upstream:

- 21 app caches from `Sources/ClearDisk/AppCacheCatalog.swift` (lines 97-106 and 115-167). Each keeps its name, path, group, description, and the "removes / keeps / note" safety text. Shared texts like `browserImpact` and `electronImpact` are written out per entry.
- 25 developer caches from `Sources/ClearDisk/DiskMonitor.swift`: the paths come from `allCachePaths()` (lines 656-740 and 784), the descriptions from `cacheDescriptions` (lines 514-597).

Each entry's `source` field names its exact upstream line.

## What changed

- Swift `\(home)/…` paths are written as `~/…`, and the risk level is left out (every vendored entry is `safe`).
- Each entry has a stable `id`, added by Swivel.
- The English texts are verbatim. Swivel translates them in `Sources/Swivel/DoctorStrings.swift`. Where a text speaks about ClearDisk itself (the Raycast note), Swivel shows its own wording instead (`DoctorStorage.displayNotes`); the vendored text is unchanged.
- Safari's cache is kept in the data but never read: macOS protects it without Full Disk Access (`DoctorPrivacy`), so at most 45 entries appear.
- Entries were left out when they are caution or risky upstream, or are not safe to move to the Trash for Swivel's purposes. Examples: whole app containers, `~/Library/Containers` (it triggers a macOS privacy prompt), Xcode Archives and Simulators, Docker data, Maven, Poetry, JetBrains caches, credentials-bearing folders, installed runtimes.
- Swivel's own safety rules are not taken from ClearDisk. `Sources/Swivel/DoctorTrash.swift` follows the same idea as ClearDisk's clean flow (Trash only, keep the cache folder itself, check afterwards that the items left), but gathers a cache's contents into one folder named after it before moving that folder, and adds its own path validation without following symbolic links, identity checks and refusing while the owning app runs.

To refresh, compare the files above at a newer revision and update the entries, the `source` lines, the revision and the translations together.
