# Agent guidance for this repo

This plugin runs inside the long-lived omarchy shell process and does its
file I/O through bash subprocesses. The Omarchy plugin marketplace's security
review ([submission #2992](https://github.com/HANCORE-linux/omarchy-plugin-marketplace/issues/2992))
rejected the first version for unhardened file handling. The rules below are
what got it approved — **every future file-I/O change must follow them**, and
they are the default for any other omarchy-shell plugin developed here.

## File I/O rules (threat model: same-user planted files in state dirs)

A hostile same-user process can plant FIFOs and symlinks at predictable paths
under `~/.local/state/…`. A naked `open()` on such a path can hang the shell
forever (FIFO) or write through to an arbitrary file (symlink). Rules:

1. **Never open a predictable state path directly** — no `FileView`, no
   `cat`/`awk`/`head` on state files, no bare shell redirections. Reads go
   through `dd … iflag=nofollow,nonblock` (refuses symlinks, never blocks on
   FIFOs). See `readJsonDirScript` in `Service.qml`.
2. **Bound everything before it reaches QML**: a per-file byte cap
   (`bs=… count=1`), a file-count cap per directory scan, and therefore a
   deterministic aggregate ceiling for each `StdioCollector`. Truncated
   entries must fail closed (JSON parse error → row dropped).
3. **Cap sender-controlled strings at snapshot time** (`TEXT_CAPS` in
   `NotificationLogic.js`) so an entry that was written always fits back
   under the read cap.
4. **Writes create same-directory temporaries with `O_CREAT|O_EXCL|O_NOFOLLOW`**
   (`dd of=… oflag=nofollow conv=excl,fsync` under an unpredictable
   `<prefix>.$$.$RANDOM$RANDOM.tmp` name), then atomically `mv -f` onto the
   final name. The predictable final name is only ever a rename target,
   never opened. `rename()` replaces a planted entry without following it.
5. **Verify state directories before touching them**: `guard_dir` (one
   `find -P -maxdepth 0 -type d -uid $(id -u) ! -perm /022` lstat — no
   symlink following, no check-then-use pair). The plugin's own dirs are
   kept `0700` by `ensureDirsProc`; shared dirs are verified, never
   re-moded.
6. **Sender-provided source paths** (avatar/image copies) may legitimately be
   symlinks, so no `O_NOFOLLOW` on the source — instead: regular-file test,
   non-blocking open, block-count size bound, `timeout` backstop, and
   size validation on the exclusive temp before rename.
7. **Deletes/renames/globs are fine as-is** (`rm`, `mv`, `ls`) — they don't
   open data files. Orphaned temps are swept at startup with prefix-scoped
   patterns (`sweepOrphanImages`).

When adding any new persistence, reuse `guardDirScript`,
`readJsonDirScript`, and `copyImagesScript` rather than writing new ad-hoc
shell I/O.

## Other repo conventions

- Commits must use the GitHub noreply author email (repo-local git config is
  already set). Never commit a personal email.
- `omarchy plugin validate .` must pass before pushing.
- After changing `Service.qml`, `NotificationLogic.js`, or `manifest.json`,
  regenerate `docs/upstream-diff.patch`:
  `diff -ru --exclude=.git --exclude=docs /usr/share/omarchy/shell/plugins/notifications . > docs/upstream-diff.patch`
- Marketplace re-review pins an exact commit SHA — after pushing a fix,
  comment the new SHA on the submission issue.
- `Service.qml` edits don't hot-reload (`keepLoaded` service): run
  `omarchy restart shell` before verifying anything.
