# Centered Scaled Notifications

An Omarchy shell plugin by `thetxeagle` that combines persistent notification history with
centered, animated, larger notification cards.

## Features

- Notification toasts centered beneath the clock on every monitor.
- Short upward swoop and fade entrance animation.
- Cards approximately 25% wider than stock, with approximately 10% larger text and icons.
- Center-bar bell that opens recent notification history.
- Click a history item to focus or relaunch its originating application.
- `Clear all` history action and per-notification dismissal.
- Right-click the bell to toggle Do Not Disturb.

The plugin clones Omarchy's notification service through the supported user-plugin mechanism. It
does not modify `/usr/share/omarchy/`.

## Install

```bash
omarchy plugin add https://github.com/thetxeagle/omarchy-centered-scaled-notifications-with-menu.git --enable
omarchy bar move thetxeagle.notifications --section center --index 3
omarchy restart shell
```

If another notification clone is installed, disable it first so only one clone owns the stock
`notifications` service:

```bash
omarchy plugin disable apurva.notifications
omarchy plugin disable soulshocker.notifications
```

The plugin's `clonedFrom` metadata disables the stock notification service when enabled.

## Use

- Left-click the bell to open or close notification history.
- Click a history card to focus or relaunch its app.
- Click `Clear all` to remove all stored history.
- Right-click the bell to toggle Do Not Disturb.

History is stored in Omarchy's existing notification state directory. The default history limit is
10 entries; add `"historyLimit": 50` to the bar entry to retain more.

## Development

Validate the plugin before installing it:

```bash
omarchy plugin validate .
```

After changing `Service.qml`, restart the shell because the service is long-lived:

```bash
omarchy restart shell
```

When Omarchy's stock notification service changes, regenerate the comparison patch:

```bash
diff -ru --exclude=.git --exclude=docs \
  /usr/share/omarchy/shell/plugins/notifications . > docs/upstream-diff.patch
```

## License

MIT. Substantial notification-service portions are derived from Omarchy's MIT-licensed shell.
