# ShortcutsLens

Drive the app with `shortcutslens` (the app binary; `shortcutslens help`). See `.claude/skills/shortcutslens/SKILL.md`. Commands live in
`Sources/ShortcutsLens/Agent/AgentCommands.swift`; test them on a Debug build with `APP_STORE=/tmp/<name>`, which starts a test copy on
its own settings, with app reports seeded from `<APP_STORE>/reports.json` (Release builds ignore it).
