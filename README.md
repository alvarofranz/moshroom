# 🍄 Moshroom

**The iPhone terminal built for driving AI agents on remote machines.**

Your agent runs where the horsepower is — a server, a VM, the workstation back home. Moshroom is
how you reach over and steer it from your pocket, over SSH or Mosh, without fighting your phone
the whole way.

## Why it's different

Every other mobile terminal is a cramped keyboard stapled under a wall of scrollback. Fine for a
quick `git pull`; agony the moment you need to brief an agent in three careful paragraphs — and then
fix the typo buried in the middle of paragraph two.

Moshroom pulls those two jobs apart. The terminal becomes a calm, read-only transcript you just read
and scroll. Everything you **send** flows through UI built for the job:

- **Moshnector** — land on a fresh shell and a one-tap connect card is already waiting: pick SSH or
  Mosh, pick a saved host, and Moshroom types the line for you.
- **Moshkitor** — a full-screen composer with room to actually think. Write long prompts, dictate
  them, scroll back to fix a word, ride the live command/snippet completion, lean on auto bullet
  lists. Your draft survives if you close it; send with a tap or `Ctrl+Enter`.
- **Moshkeys** — floating round keys that fire *live* into the agent or TUI: `Esc`, `Tab`, `Ctrl-C`,
  a circular arrow d-pad, digits and letters. No menu-diving for `Esc` mid-session.
- **Moshdrop** — attach a photo, PDF, log or any text/code file and it drops inline right where your
  cursor sits. On send, Moshroom SFTPs it to `~/.moshroom/uploads/` on your host and swaps the chip
  for its path, so the agent reads it exactly where you meant. Photos are downscaled and re-encoded
  to JPEG on the phone first (HEIC included) — uploads stay light and land in a format any agent or
  vision model can read. Your server needs nothing installed.
- **Tap-to-copy** — long-press any word to select and copy it; agents and apps can push straight to
  the iOS clipboard over OSC 52, even from inside a full-screen TUI.
- **Snippets** — keep the incantations you always retype (`ssh -t box 'tmux a'`) in tidy folders and
  drop them into the composer in a tap.

## Screenshots

<!-- TODO: add a screenshot / short screen-recording of Moshkitor + Moshkeys driving an agent -->

## Build & run on a device

You'll need an iPhone on **iOS 16.1+** with Developer Mode on, the full **Xcode.app**, and an Apple
signing team.

```bash
./get_frameworks.sh                                   # self-hosted xcframeworks (see FRAMEWORKS.md)
cp template_setup.xcconfig developer_setup.xcconfig   # then fill in TEAM_ID + bundle/group/cloud/keychain ids
./deploy.sh                                           # build, install & launch on the connected iPhone
```

The 8 binary frameworks (mosh, SSH, crypto, ios_system) are **self-hosted on this repo's own release**
and slimmed to the iOS-device slice — no Blink, no third-party hosting. Details in
[`FRAMEWORKS.md`](FRAMEWORKS.md).

## License

Moshroom is free software under the **GNU General Public License v3** — see [`COPYING`](COPYING).
Bundled third-party components (Mosh, libssh2, the fonts, and more) keep their own licenses, noted in
their source headers and in the app's About screen. Use it, study it, share it, change it — all under
the GPLv3.
