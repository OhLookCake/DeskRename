# DeskRename

A native menu bar utility for naming your macOS desktops (Spaces). Requires macOS 26 Tahoe.

1. Open `build/DeskRename.app`.
2. Type a name next to any desktop and click **Save Names**. Clear a name and save to restore its default.
3. Click **Open Mission Control**, or use your usual shortcut or gesture. Move the pointer to the top to reveal the desktop thumbnails and your names.

Use the overlapping rectangles in the menu bar to reopen the editor or quit. The menu bar shows the current desktop’s custom name when it has one. Names are stored locally and keyed to the desktop’s identity, so they follow the desktop when you reorder Spaces. Full-screen app Spaces aren't editable.

macOS does not provide a way for third-party apps to change the Dock’s built-in text. DeskRename draws click-through labels over the expanded thumbnail captions while it runs. Choose **Allow Reading Dock Preview Positions…** in the menu bar to let DeskRename align labels using positions reported by the Dock. When those positions are unavailable, DeskRename estimates them and waits for the row to recenter if the pointer moves too quickly to place the labels. DeskRename uses read-only SkyLight calls to find Spaces and works without Screen Recording or changes to System Integrity Protection.
