# Peek design assets

- `mark/`: the winking pup (`peek-mark.svg`), the five moods (idle, working, needs, done, failed) and `peek-blink.svg`, a 2-second blink loop that stops under reduced motion.
- `icon/`: the app icon as SVG, plus PNG exports at 1024, 512, 256, 128, 64, 32 and 16 px.
- `lockup/`: mark and wordmark side by side, for dark and light grounds (SVG and 2x PNG, transparent).
- `wordmark/`: the lowercase "peek" wordmark, where the two e's are eyes (dark and light, SVG and 2x PNG).
- `social/`: the 1280x640 GitHub social preview.
- `stickers/`: the five moods as 512 px transparent PNGs with a thin off-white outline.

The in-app character is drawn in code (`Sources/Peek/Mascot.swift`) and simplified for its 22x16 pt box; these files are the full-size art.

Palette: near-black `#0B0B0C`, off-white `#ECEBE6`, amber `#F5A524`, green `#3CCB7F`, red `#F0524F`, blush `#EDBFB6`.
