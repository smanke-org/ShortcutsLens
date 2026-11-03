---
name: shortcutslens
description: Read the keyboard shortcuts on this Mac with the `shortcutslens` command, through the ShortcutsLens app: search shortcuts by app, keys or source, show where one comes from, list conflicts, check whether a key combination is free, suggest free ones, and hide shortcuts from its lists. Use when the user asks which shortcut does something, whether keys are taken, why a shortcut doesn't work, wants a free shortcut, or names ShortcutsLens.
---

# ShortcutsLens

`shortcutslens` runs commands in the ShortcutsLens app, so answers match its window. If the
app is closed, the command opens it in the background. If `shortcutslens` isn't on PATH, use
`/Applications/ShortcutsLens.app/Contents/MacOS/ShortcutsLens` the same way.

## Rules

- Always add `--json` and read the JSON. Exit 0 is ok; otherwise read `error.code` and
  `error.message`, and do what the message says (`busy`: the first scan is still running).
- ShortcutsLens only knows shortcuts that macOS and apps write down or report. "free" means
  nothing it can see uses the keys, not a guarantee. Never press keys to test a shortcut.
- Keys can be written `⌃⌥⌘K`, `ctrl+opt+cmd+k`, `cmd shift space` or `@$k`.
- Find ids with `shortcutslens shortcuts list`. An id is 8 characters; any unique start works.
- `shortcuts hide` changes the person's settings (synced to their other Macs). Ask first;
  `shortcuts unhide` undoes it.
- `quickview open` and `open` put a panel or window on screen. Only when the person asks.
- To try something without real settings, run a Debug build with `APP_STORE=/tmp/shortcutslens-test` in front.

## Main commands

| Command | Does |
| --- | --- |
| `shortcutslens status --json` | Version, last scan, counts of shortcuts, conflicts and apps |
| `shortcutslens shortcuts list [--search T] [--app A] [--keys K] [--source S] [--conflicts] --json` | Find shortcuts |
| `shortcutslens shortcuts show <id> --json` | Where it came from, how to change it, what else uses its keys |
| `shortcutslens conflicts list [--app A] --json` | Keys that two or more shortcuts claim |
| `shortcutslens keys check "<keys>" --json` | Is it free? Everything that uses it |
| `shortcutslens keys suggest [--modifiers M] --json` | Free shortcuts to pick from |
| `shortcutslens apps list [--search T] [--running] --json` | Apps with shortcuts |

Everything else: `shortcutslens help`, and `shortcutslens help <command>` for its options.
