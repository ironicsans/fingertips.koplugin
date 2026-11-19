# Fingertip — a KOReader plugin

When you long-press and drag to select text, your fingertip covers the words you're selecting. Fingertip fixes that, and makes the steps after selecting easier too.

**While you drag**
- A copy of the selected text appears 2¼ lines above the real text, in a panel with a thick, rounded outline. It's the page's own pixels at 1:1 size, not magnified.
- The panel also shows a sliver of the surrounding text in light grey: about three letters on each side and half a line above and below. The selection inside the copy keeps the same shading it has on the page.
- Each line's copy stays where it first appears. The current line's copy grows to the right, and when the selection reaches a new line, that line's copy is added below. A multi-line selection gets one merged panel whose outline steps in and out with the lines, with every corner rounded. When two lines barely overlap side to side, for example the last word of one line and the first word of the next, they get two separate boxes.
- Handles appear at both ends of the selection as soon as you start, and they show up in the copy too.
- On the top line of a page, where there's no room above, the panel goes below the selection.

**When you lift your finger**
- The panel disappears. In its place, an action bar appears above the selection, leaving the same gap, so it never covers the selection or its handles. When there's no room above, it goes below.
- The bar is built from the buttons of KOReader's own highlight popup, including buttons that other plugins add. You choose which ones appear and in what order.
- It shows one set at a time. **More** swaps in the next set and goes back to the first set after the last one.
- Tap elsewhere to close the bar and drop the selection, the same as KOReader's popup. Long-press elsewhere to start a new selection.
- A single-word long-press still opens the dictionary right away, as KOReader normally does.

**Adjusting the selection**
- Drag either handle. While you drag, the bar steps aside and the lifted copy comes back. When you let go, the bar returns showing its first set.

## Install on the Kobo

1. Plug the Kobo into the Mac over USB and choose **Connect** on the Kobo.
2. Open `KOBOeReader/.adds/koreader/plugins/`. `.adds` is a hidden folder: in Finder, press ⌘⇧. to show hidden files.
3. **Delete the old `liftedselection.koplugin` folder** if it's there. If you leave it, both plugins run at once.
4. Copy the `fingertip.koplugin` folder into `plugins/`. You can also unzip `dist/fingertip.koplugin.zip` there.
5. Eject the Kobo, then restart KOReader. In KOReader, open the top menu, go to the hamburger tab and choose **Exit**, then start KOReader again.

## Settings

Look under **Tools → Fingertip** in the top menu while a book is open. You'll find:

- **Fingertip on**: when it's off, selecting works exactly as it does without the plugin.
- **Action bar**: opens a screen for arranging the bar.
  - Choose **One row per set** (3 actions plus More) or **Two rows per set** (7 actions plus More).
  - Tap an action to pick it, then use **Move up** and **Move down**.
  - Tap an action's box to put it on the bar or take it off.
  - The list is grouped the way the bar shows it: first set, second set (after More), and so on. Actions you've taken off the bar are listed last.
  - Actions marked "(only when it applies)", like Follow Link, appear on the bar only when they're relevant, for example when you've selected a link.
- **Outline thickness**: Thin, Medium (default), Thick or Extra thick.
- **Corner rounding**: Square, Slight, Medium (default) or Round.
- **Drop shadow**: None (default), Hard or Soft.

The last three are temporary. Once you've picked values, they'll be hardcoded and removed from the menu. Settings from the old Lifted selection plugin don't carry over.

## Testing on the Mac

`emulator/` holds a copy of KOReader's own macOS build, a sample book, and a scripted test:

```bash
emulator/tools/run.sh
```

This opens the book in a window sized like a Clara BW. Press and hold with the mouse, then drag.

```bash
emulator/tools/run.sh demo
```

This runs a scripted session and saves screenshots to `emulator/shots/`. Set `FT_DEMO_SCENARIO` to choose the scenario:
- `main` (the default): hold, drag, release, page through the bar with More, drag both handles, then tap elsewhere.
- `top`: a selection on the top line of a page.
- `split`: a selection from the end of one line to the start of the next.
- `arrange`: the Action bar settings screen.
- `rows2`: the two-row bar.

Other options:
- `FT_DEMO_SHOTS=folder` saves the screenshots to a different folder.
- `FT_DEMO_STYLE=5,14,soft` sets thickness, rounding and shadow, in the plugin's internal units.
- Each step also saves a `-bb8.png` render in 8-bit grey, the format the Clara BW uses.

The `fingertipdemo` plugin is only for this testing. Don't copy it to the Kobo.
