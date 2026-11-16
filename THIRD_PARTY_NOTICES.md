# Third-party notices

## Coucou

Source: github.com/Louis-CFM/coucou, commit 0d7fe58884d9.

Coucou's name, character, icon, sounds and media are not used in Peek. Only code is adapted.

### Files adapted

- `Sources/Peek/Server.swift` (from `NotchBuddy/Sources/App/HookServer.swift` @ 0d7fe58, socket setup, accept loop, peer-uid check and connection ceiling, lines 480-630)
- `Sources/PeekCore/AskQuestion.swift` (from `NotchBuddy/Sources/App/AskQuestion.swift` @ 0d7fe58, `parse` and `buildAnswers`)
- `Sources/PeekCore/Diff.swift` (from `NotchBuddy/Sources/CoucouKit/DiffEngine.swift` @ 0d7fe58, LCS line diff and hunks; `forTool` adapted from `buildFileDiff` in `NotchBuddy/Sources/App/HookServer.swift`, around line 1652)
- `Sources/PeekCore/Usage.swift` (from `NotchBuddy/Sources/App/ClaudePlanGauge.swift` @ 0d7fe58, `parse` and `merge`)
- `Sources/PeekCore/Terminals.swift` (from `NotchBuddy/Sources/App/ClaudeHost.swift` @ 0d7fe58, terminal bundle-id and TERM_PROGRAM tables; VS Code and Cursor rows added)
- `Sources/Peek/Focus.swift` (`activate` from `ClaudeHost.activate` in `NotchBuddy/Sources/App/ClaudeHost.swift` @ 0d7fe58, activation through Launch Services)
- `Sources/PeekCore/Presence.swift` (from `NotchBuddy/Sources/App/IslandStateMachine.swift`, `NotchBuddy/Sources/App/IslandDisplayChoice.swift` and `NotchBuddy/Sources/CoucouKit/IslandScreenGeometry.swift` @ 0d7fe58; three-state hover machine, screen choice resolver, 80x24 no-notch bar)
- `Sources/PeekCore/Shortcuts.swift` (from `NotchBuddy/Sources/App/ShortcutLogic.swift` @ 0d7fe58, modifier bits, Carbon modifier conversion, display string)
- `Sources/Peek/Hotkeys.swift` (from `NotchBuddy/Sources/App/HotKeyCenter.swift` @ 0d7fe58, Carbon `RegisterEventHotKey` handler and registration table)
- `Sources/Peek/Store.swift` (`Sounds.customURL` from `customURL` in `NotchBuddy/Sources/App/SoundEngine.swift` @ 0d7fe58, custom sound lookup)

### License text

MIT License

Copyright (c) 2026 Louis Raillé

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
