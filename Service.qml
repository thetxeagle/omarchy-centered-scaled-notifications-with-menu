// Notification service for the omarchy shell.

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Notifications
import qs.Commons

import "components"
import "NotificationLogic.js" as NotificationLogic

Item {
  id: service

  // Injected by omarchy-shell (the first-party service loader).
  property var shell: null
  property var manifest: null

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  readonly property string home: Quickshell.env("HOME")
  // History + DND live under XDG_STATE_HOME: they're persistent user state
  // (the notifications received, the last-set DND preference), not
  // regeneratable cache that a `rm -rf ~/.cache` should wipe.
  readonly property string stateDir: home + "/.local/state/omarchy/"
  readonly property string settingsPath: stateDir + "notifications.json"
  // One file per on-screen popup, so live toasts survive shell restarts.
  // A file exists exactly as long as its popup is showing: written when the
  // toast appears, moved into historyDir when it expires, is dismissed, or is
  // acted upon.
  readonly property string popupStateDir: stateDir + "notifications/"
  // The notifications that already left the screen, one file each, trimmed to
  // the newest historyLimit. This directory IS the history: `showHistory`
  // replays exactly what has been moved in here.
  readonly property string historyDir: popupStateDir + "history/"
  // Copies of the avatars/images persisted entries reference — the sender's
  // originals don't outlive the notification (see persistablePopup). Each
  // copy lives and dies with the JSON file whose stem it carries.
  readonly property string imagesDir: popupStateDir + "images/"
  // Corner radius is shared with the menu and shell panels.
  // It mirrors Hyprland's current decoration:rounding value.
  readonly property int cornerRadius: Style.cornerRadius
  // Toasts are fixed to the top-right corner. They only clear the omarchy bar
  // when the bar occupies the top or right edge, so left/bottom bars do not
  // pull notification popups away from the expected top-right location.
  // Falls back to the bar's default size (26 horizontal / 28 vertical) when
  // shell.bar isn't reachable so the popup never lands on top of the bar.
  readonly property string barPosition: shell && shell.barConfig ? String(shell.barConfig.position || "top") : "top"
  readonly property bool barVertical: barPosition === "left" || barPosition === "right"
  readonly property int defaultBarSize: barVertical ? Style.bar.sizeVertical : Style.bar.sizeHorizontal
  readonly property int liveBarSize: shell && shell.bar && !shell.bar.barHidden ? Math.max(0, shell.bar.barSize) : defaultBarSize
  readonly property int barClearance: liveBarSize + Style.gapsOut

  // Live Notification objects by originalId, kept OUT of the ListModels: a
  // QObject stored in a model role becomes a dangling C++ pointer when the
  // server destroys the notification (sender close, DND untrack, dismiss),
  // and the next read of that role segfaults in QQmlListModel::data. A JS
  // map only holds a wrapper, which degrades to a catchable error instead.
  property var liveRefs: ({})

  // PersistentProperties handles in-process QML reloads. The on-disk
  // notifications.json file is the cross-restart backstop — its `dnd` key
  // is hydrated into persisted.doNotDisturb on startup and written back via
  // a debounced save timer.
  PersistentProperties {
    id: persisted
    reloadableId: "omarchy-notifications"
    property bool doNotDisturb: false
    onDoNotDisturbChanged: {
      // Suppress the write that load-time hydration would otherwise trigger.
      if (service._hydrating) return
      service.scheduleSettingsSave()
    }
  }

  // Guards onDoNotDisturbChanged while we're hydrating from disk so the
  // hydration assignment doesn't immediately schedule a write-back.
  property bool _hydrating: false

  readonly property alias doNotDisturb: persisted.doNotDisturb

  function setDoNotDisturb(value) {
    persisted.doNotDisturb = !!value
  }

  // ------------------------------------------------- stock silence button
  //
  // The bar's silence indicator (bar/indicators/Dnd.qml in the shell) finds
  // its service with firstPartyServiceFor("omarchy.notifications") — a bare
  // map lookup. Unlike summon/toggle/call, serviceFor does not route through
  // PluginRegistry.resolveEnabledId(), so with this clone enabled (and the
  // stock plugin therefore disabled) that lookup returns null and the button
  // goes dead. Until serviceFor learns clone resolution upstream, park a
  // bridge under the stock id so the indicator finds a working DND toggle.
  //
  // Only ever the bridge, never `service` itself: the shell's _syncServices
  // destroys whatever sits under a disabled plugin's id on every plugin
  // rescan, and that destroy must cost nothing but the bridge. The typed
  // property nulls itself when it happens, and stockServiceSlot — whose
  // binding re-runs on every _services reassignment — retriggers the
  // registration.
  readonly property string cloneSourceId:
    manifest && manifest.omarchy ? String(manifest.omarchy.clonedFrom || "") : ""
  property QtObject dndBridge: null

  Component {
    id: dndBridgeComponent
    QtObject {
      readonly property bool doNotDisturb: service.doNotDisturb
      function setDoNotDisturb(value) { service.setDoNotDisturb(value) }
    }
  }

  readonly property var stockServiceSlot:
    shell && cloneSourceId ? shell.serviceFor(cloneSourceId) : null
  onStockServiceSlotChanged: Qt.callLater(registerDndBridge)
  onCloneSourceIdChanged: Qt.callLater(registerDndBridge)
  onShellChanged: Qt.callLater(registerDndBridge)

  function registerDndBridge() {
    if (!shell || !shell._services || !cloneSourceId) return
    // Never clobber a real instance — the stock service being present means
    // the clone is on its way out (or misconfigured to run beside it).
    if (shell._services[cloneSourceId]) return
    if (!dndBridge) dndBridge = dndBridgeComponent.createObject(service)
    var next = ({})
    for (var k in shell._services) next[k] = shell._services[k]
    next[cloneSourceId] = dndBridge
    shell._services = next
  }

  Component.onDestruction: {
    // Leave nothing dangling under the stock id: a dead bridge there would
    // block ensureService from ever loading the re-enabled stock plugin.
    if (!shell || !shell._services || !dndBridge) return
    if (shell._services[cloneSourceId] !== dndBridge) return
    var next = ({})
    for (var k in shell._services) if (k !== cloneSourceId) next[k] = shell._services[k]
    shell._services = next
  }

  // popupModel feeds the on-screen toast stack — the only model the service
  // keeps. Everything a toast leaves behind lives on disk under historyDir.
  //
  // Aliased as a property so consumers outside this Item's id scope can bind
  // to it. QML ids aren't visible to external consumers without the alias.
  property alias popupModel: popupModel
  ListModel { id: popupModel }

  // How many notifications the history directory keeps. Defaults to the
  // stock 10; the notification center widget pushes the user's
  // "historyLimit" setting from its shell.json bar entry over it (see
  // NotificationCenter.qml), which is also why this is writable.
  property int historyLimit: 10

  // A lowered limit would otherwise leave the directory over-full until the
  // next archive happens to trim it — trim right away instead, so a changed
  // setting takes effect without waiting for notification traffic.
  onHistoryLimitChanged: {
    enqueuePopupFileJob(["bash", "-c",
      "hist=\"$1\" limit=\"$2\" imgs=\"$3\"\n" + trimHistoryScript, "--",
      historyDir, String(historyLimit), imagesDir])
    historyMutated()
  }

  // How many history entries the `showHistory` toast replay puts on screen.
  // Kept at the stock 10 — replaying historyLimit toasts would flood the
  // screen; the notification center is the place to read the full history.
  readonly property int replayLimit: 10

  readonly property int lowPopupDuration: 5000
  readonly property int normalPopupDuration: 8000
  readonly property int maxPopupDuration: 30000

  function durationFor(urgency, expireTimeout) {
    switch (urgency) {
    case NotificationUrgency.Critical:
      return 0
    case NotificationUrgency.Low:
      return Math.min(maxPopupDuration, Math.max(lowPopupDuration, requestedDuration(expireTimeout)))
    default:
      return Math.min(maxPopupDuration, Math.max(normalPopupDuration, requestedDuration(expireTimeout)))
    }
  }

  function requestedDuration(expireTimeout) {
    // FreeDesktop notification spec (and Quickshell) report expireTimeout in
    // milliseconds, so pass it through directly.
    var ms = Number(expireTimeout || 0)
    if (!isFinite(ms) || ms <= 0) return 0
    return Math.round(ms)
  }

  // DND bypass: only let through notifications we trust to be intentional
  // and rare.
  //   - omarchy-action: a user-action confirmation toast ("Theme changed",
  //     "Screenshot saved"). The user JUST did something — their feedback
  //     should show.
  //   - urgency=critical AND app_name=notify-send: bare-CLI emergency alerts.
  //     Trusted because it's almost always omarchy or system shell scripts —
  //     chat apps set app_name to their brand (Discord/Slack/Vesktop), which
  //     falls outside this rule.
  function shouldBypassDnd(notification) {
    return NotificationLogic.shouldBypassDnd(notification, NotificationUrgency.Critical)
  }

  function snapshotOf(notification) {
    return NotificationLogic.snapshotOf(notification, Date.now())
  }

  // A notification nobody looks back at:
  //   - the freedesktop `transient` hint is set ("popup only, don't store")
  //   - app_name is "notify-send" (the CLI default — means the sender
  //     didn't bother declaring an identity, so it's almost certainly
  //     ephemeral test/feedback noise)
  //   - app_name is "omarchy-action" (Omarchy's own user-action toasts —
  //     the user just triggered them)
  // Their toasts still land in history like any other once they've been on
  // screen; the distinction only decides whether a DND-silenced one is worth
  // recording at all.
  function isEphemeral(notification) {
    var transient = false
    try {
      transient = !!(notification.hints && notification.hints["transient"])
    } catch (e) { transient = false }
    return transient || NotificationLogic.isEphemeralApp(String(notification.appName || ""))
  }

  function handleNotification(notification) {
    // Without `tracked = true` the Notification object is destroyed as soon
    // as this signal handler returns, which would null out the `ref` we just
    // captured for the popup card.
    notification.tracked = true
    var snapshot = snapshotOf(notification)
    liveRefs[snapshot.originalId] = notification
    // Guard the delete: a newer notification may have reused this originalId
    // (freedesktop replaces_id) and taken over the map slot.
    notification.closed.connect(function() {
      if (service.liveRefs[snapshot.originalId] === notification)
        delete service.liveRefs[snapshot.originalId]
    })

    // DND bypass rules: chat apps abuse urgency=critical to force
    // visibility, so critical alone isn't enough — we also require the
    // sender to be CLI-style. See shouldBypassDnd().
    if (service.doNotDisturb && !shouldBypassDnd(notification)) {
      // The toast never shows, so the only record a silenced notification
      // can leave is a history entry. Write it straight into history —
      // "what did I miss while silenced" is exactly what history is for.
      if (!isEphemeral(notification)) {
        writeSilenced(notification, snapshot)
        return
      }
      delete liveRefs[snapshot.originalId]
      notification.tracked = false
      return
    }

    persistPopupFile(snapshot)
    watchForUpdates(notification, snapshot)
    // Qt.callLater avoids "QV4::Object::insertMember" crashes when a
    // Repeater is mid-incubation while we mutate its model.
    Qt.callLater(function() {
      removePopupsByOriginalId(snapshot.originalId, NotificationLogic.popupFileName(snapshot))
      popupModel.insert(0, snapshot)
      // An update that arrived while the insert was deferred found no row to
      // write to, and a property that already changed will not change again.
      // Reading the object once the row exists catches up on it.
      service.refreshPopup(notification, snapshot.originalId, snapshot.timestamp)
    })
  }

  // Persist a silenced notification, held tracked until its content is
  // stable: untracking tells the sender its notification closed (Chromium
  // then deletes its avatar file), and a replaces_id update lands on this
  // object without a second onNotification — releasing on a stale snapshot
  // would drop it. Each catch-up write reuses the original file identity.
  function writeSilenced(notification, written) {
    writeHistoryFile(written, function() {
      var updated = null
      try {
        updated = NotificationLogic.replacementSnapshot(notification, written.originalId, written.timestamp)
      } catch (e) {
        // Torn down by the server while the write was queued.
      }
      if (updated && NotificationLogic.popupRowChanged(written, updated)) {
        service.writeSilenced(notification, updated)
        return
      }
      service.releaseSilenced(notification, written.originalId)
    })
  }

  // Let go of a DND-silenced notification once its history write has run.
  // The id may have been reused and the object torn down meanwhile.
  function releaseSilenced(notification, originalId) {
    if (liveRefs[originalId] === notification) delete liveRefs[originalId]
    try {
      notification.tracked = false
    } catch (e) {
      // Object already destroyed by the server — nothing left to release.
    }
  }

  // Everything the card draws. A change to any of these is a client updating
  // the notification in place, which is the only kind of update we ever hear
  // about after the popup exists.
  readonly property var updateSignals: [
    "summaryChanged", "bodyChanged", "appNameChanged", "appIconChanged",
    "imageChanged", "urgencyChanged", "expireTimeoutChanged", "hintsChanged"
  ]

  // A client that updates a notification through replaces_id does not produce
  // a second onNotification: the server writes the new content onto the object
  // we are already holding. The card draws a snapshot copied out of that
  // object — deliberately, since the object itself must stay out of the model
  // — so nothing reaches the screen until we copy it again.
  function watchForUpdates(notification, snapshot) {
    function refresh() {
      service.refreshPopup(notification, snapshot.originalId, snapshot.timestamp)
    }

    for (var i = 0; i < updateSignals.length; i++) {
      var signal = notification[updateSignals[i]]
      if (signal && typeof signal.connect === "function") signal.connect(refresh)
    }
  }

  function refreshPopup(notification, originalId, timestamp) {
    // A newer notification may have taken this id over, and the object may
    // outlive its popup — in both cases there is nothing here to refresh.
    if (service.liveRefs[originalId] !== notification) return

    var updated
    try {
      updated = NotificationLogic.replacementSnapshot(notification, originalId, timestamp)
    } catch (e) {
      // Object torn down by the server while the signal was in flight.
      return
    }

    var roles = NotificationLogic.popupRoles()
    for (var i = 0; i < popupModel.count; i++) {
      var row = popupModel.get(i)
      if (!row || row.originalId !== originalId || row.timestamp !== timestamp) continue
      if (!NotificationLogic.popupRowChanged(row, updated)) return
      for (var r = 0; r < roles.length; r++) popupModel.setProperty(i, roles[r], updated[roles[r]])
      // The file name is the timestamp and id this popup was persisted under,
      // so the rewrite lands on the same file: a restart restores the version
      // last shown, and so does the copy that ends up in history.
      persistPopupFile(updated)
      return
    }
  }

  // A restored row carries an id from the previous server generation, and
  // the new server hands out ids from 1 again — so a fresh notification
  // with the same originalId is a coincidence, not the same notification.
  // The timestamp (via the file name) disambiguates: it travels with the
  // row through every model and file round-trip.
  function isRestoredRow(row) {
    return !!row && !!restoredPopups[NotificationLogic.popupFileName(row)]
  }

  // A notification arriving under an originalId a popup on screen already
  // holds supersedes it, so that row leaves the screen. Its file is deleted
  // rather than archived: the row taking its place archives itself when it
  // goes, and history would otherwise hold two entries for what the sender
  // means as one notification.
  // keepFileName is the replacement's own file: a same-millisecond
  // replacement shares the replaced row's filename, and the new write is
  // already queued — deleting that path here would erase the replacement's
  // only file.
  function removePopupsByOriginalId(originalId, keepFileName) {
    for (var i = popupModel.count - 1; i >= 0; i--) {
      var row = popupModel.get(i)
      if (!row || row.originalId !== originalId) continue
      // Not a replaces_id match — see isRestoredRow. Removing it here
      // would silently kill a restored critical alert on an unrelated ping.
      if (isRestoredRow(row)) continue
      if (NotificationLogic.popupFileName(row) !== keepFileName) deletePopupFileFor(row)
      popupModel.remove(i)
    }
  }

  function dismissPopup(index) {
    removePopup(index, "dismiss")
  }

  function expirePopup(index) {
    removePopup(index, "expire")
  }

  function removePopup(index, reason) {
    if (index < 0 || index >= popupModel.count) return
    var entry = popupModel.get(index)
    var originalId = entry ? entry.originalId : -1
    // A restored row has no live server object, and its old-generation id
    // may meanwhile belong to a fresh notification — resolving liveRefs by
    // id would dismiss that unrelated notification at the server.
    var restored = isRestoredRow(entry)
    var ref = !restored && originalId >= 0 ? liveRefs[originalId] : null
    // The popup is leaving the screen — for any reason — so its file must not
    // survive to the next shell restart. It becomes the newest history entry
    // instead. Rows that never had a file (a history replay, the empty-history
    // placeholder) archive to nothing, which the move tolerates.
    if (entry) {
      archivePopupFileFor(entry)
      if (restored) delete restoredPopups[NotificationLogic.popupFileName(entry)]
    }
    popupModel.remove(index)
    if (ref) {
      try {
        if (ref.tracked) {
          if (reason === "expire" && typeof ref.expire === "function") ref.expire()
          else ref.dismiss()
        }
      } catch (e) {
        // Object already torn down by the server — nothing to dismiss.
      }
    }
  }

  function clearPopups() {
    while (popupModel.count > 0) dismissPopup(0)
  }

  // Run the popup's click action, then dismiss. Omarchy's own toasts carry the
  // action as an argv vector in the `execArgv` role (see execArgvFromHints),
  // which the persistence files preserve, so restored toasts stay clickable.
  // Third-party clients register a libnotify action under the canonical
  // identifier "default" instead; that one only works while the sender is live.
  function invokePopupDefault(index) {
    if (index < 0 || index >= popupModel.count) return
    var entry = popupModel.get(index)

    // Run the argv (via Util.execArgv, no shell interpretation). Detached so it
    // outlives the shell, which installer toasts depend on: they restart it.
    var argv = NotificationLogic.parseExecArgv(entry ? entry.execArgv : "")
    if (argv) {
      Util.execArgv(argv)
      dismissPopup(index)
      return
    }
    // Restored rows have no live actions, and looking up liveRefs by their
    // old-generation id could fire an unrelated fresh notification's action.
    var ref = entry && !isRestoredRow(entry) ? liveRefs[entry.originalId] : null
    var invoked = false
    try {
      if (ref && ref.actions) {
        for (var i = 0; i < ref.actions.length; i++) {
          var action = ref.actions[i]
          if (action && action.identifier === "default") {
            action.invoke()
            invoked = true
            break
          }
        }
      }
    } catch (e) {
      // Notification already torn down by the server — fall through to focus.
      console.warn("invoke default failed:", e)
    }
    // Chat apps (Slack, Discord, Vesktop, etc.) rarely register a "default"
    // libnotify action — they just expect clicking the notification to
    // focus their window. Fall back to focusing the sending app by class
    // (relaunching it if it's gone) so that click-to-jump actually works.
    if (!invoked) focusApp(entry)
    dismissPopup(index)
  }

  // Try to focus an existing Hyprland window matching the notification's
  // sender (the helper matches window class case-insensitively); when none
  // exists — the app was closed since it notified — fall back to launching
  // its desktop entry. `done(handled)` reports whether either step worked,
  // so the notification center can decide whether the entry was dealt with.
  property var focusAppDone: null
  property string focusAppName: ""
  property string focusAppIcon: ""

  function focusApp(entry, done) {
    var app = entry && entry.app ? String(entry.app) : ""
    if (!app || focusAppProc.running) {
      if (done) done(false)
      return
    }
    focusAppName = app
    focusAppIcon = entry.appIcon ? String(entry.appIcon) : ""
    focusAppDone = done || null
    focusAppProc.command = [
      service.omarchyPath + "/bin/omarchy-hyprland-focus-app", app]
    focusAppProc.running = true
  }

  Process {
    id: focusAppProc
    running: false
    onExited: function(exitCode) {
      var done = service.focusAppDone
      service.focusAppDone = null
      // Non-zero means no window matched — the sender is not running.
      var handled = exitCode === 0
        || service.launchApp(service.focusAppName, service.focusAppIcon)
      if (done) {
        try {
          done(handled)
        } catch (e) {
          console.warn("notifications: focus-app callback failed:", e)
        }
      }
    }
  }

  // Resolve the sender to a desktop entry and launch it. Notifications carry
  // a human brand name ("Discord") in app_name while appIcon often holds the
  // desktop id — try both. Launching through uwsm-app + gtk-launch mirrors
  // the app launcher (AppLibrary.launch): a scope under app-graphical.slice,
  // gtk-launch as the desktop-entry resolver.
  function launchApp(appName, appIcon) {
    var entry = null
    try {
      var name = String(appName || "")
      if (name) entry = DesktopEntries.heuristicLookup(name)
      var icon = String(appIcon || "")
      if (!entry && icon && icon.indexOf("/") === -1)
        entry = DesktopEntries.heuristicLookup(icon)
    } catch (e) {
      entry = null
    }
    if (!entry || !entry.id) return false
    Util.execDetached("uwsm-app -- gtk-launch " + Util.shellQuote(entry.id + ".desktop"))
    return true
  }

  // Creates the state tree and pins this plugin's own directories to 0700 —
  // notification content is private. The shared omarchy state dir ($1) is
  // left as-is; guard_dir only ever verifies it. chmod skips anything that
  // is a symlink instead of a real directory.
  Process {
    id: ensureDirsProc
    command: ["bash", "-c",
      "mkdir -p \"$1\" \"$2\" \"$3\" \"$4\" || exit 0\n" +
      "for d in \"$2\" \"$3\" \"$4\"; do [[ -L $d ]] || chmod 700 -- \"$d\"; done", "--",
      service.stateDir, service.popupStateDir, service.historyDir, service.imagesDir]
    running: false
  }

  // ---------------------------------------------------- popup persistence
  //
  // Mirror every on-screen popup to its own file under popupStateDir so
  // toasts survive shell restarts (notably the restart `omarchy-update`
  // performs). Writes, moves and deletes go through one serialized queue: a
  // burst of replaces_id updates must not race a single reused Process, and
  // ordering guarantees a delete issued after a write wins.

  // Popups restored from a previous shell process, keyed by their file
  // name (timestamp-originalId) since ids alone repeat across server
  // generations. The replaces_id handling and liveRefs lookups must not
  // match these rows against fresh notifications.
  property var restoredPopups: ({})

  // Entries are either { command, done } for a file job or { read: true } for
  // a replay's directory read. Queueing the read rather than running it beside
  // the queue is what makes it a barrier: it takes its place in line, so the
  // history it sees is the one that existed when the replay was asked for.
  // Everything queued after it — a clear, an archive, a silenced write — waits
  // for it, and no amount of later traffic can push it back.
  property var popupFileQueue: []

  // Done callback of the job popupFileProc is currently running.
  property var runningPopupFileJobDone: null

  function enqueuePopupFileJob(command, done) {
    popupFileQueue = popupFileQueue.concat([{ command: command, done: done || null }])
    runNextPopupFileJob()
  }

  function enqueueHistoryRead() {
    popupFileQueue = popupFileQueue.concat([{ read: true }])
    runNextPopupFileJob()
  }

  function enqueueHistoryModelRead() {
    popupFileQueue = popupFileQueue.concat([{ modelRead: true }])
    runNextPopupFileJob()
  }

  function runNextPopupFileJob() {
    if (readHistoryProc.running || historyModelProc.running || popupFileProc.running) return
    if (popupFileQueue.length === 0) return

    var job = popupFileQueue[0]
    popupFileQueue = popupFileQueue.slice(1)

    if (job.read) {
      startHistoryRead()
      return
    }

    if (job.modelRead) {
      startHistoryModelRead()
      return
    }

    popupFileProc.command = job.command
    service.runningPopupFileJobDone = job.done || null
    popupFileProc.running = true
  }

  Process {
    id: popupFileProc
    running: false
    onExited: {
      var done = service.runningPopupFileJobDone
      service.runningPopupFileJobDone = null
      if (done) {
        try {
          done()
        } catch (e) {
          console.warn("notifications: file job callback failed:", e)
        }
      }
      service.runNextPopupFileJob()
    }
  }

  // Refuse to touch a state directory that is not a real, user-owned
  // directory free of group/other write bits. find -P answers with a single
  // lstat: no symlink is followed, and there is no separate check-then-use
  // pair to race. Callers run `guard_dir "$dir" || exit 0` before any file
  // work. (ensureDirsProc additionally keeps this plugin's own dirs at 0700;
  // the shared omarchy state dir is only verified, never re-moded.)
  readonly property string guardDirScript:
    "guard_dir() { [[ -n $(find -P \"$1\" -maxdepth 0 -type d -uid \"$(id -u)\" ! -perm /022 2>/dev/null) ]]; }\n"

  // Consumes the remaining args as from/to pairs. The source path is
  // sender-controlled and may grow, block, or become a FIFO mid-copy, so the
  // copy is one bounded dd: a non-blocking open (a FIFO reads as an
  // immediate error, not a parked queue), a block count just over the 5 MiB
  // budget so oversized sources are detected and rejected, and a hard
  // timeout as the backstop. The source may legitimately be a symlink (icon
  // themes are full of them), so O_NOFOLLOW is NOT applied to it — only to
  // the destination temp, which is created O_CREAT|O_EXCL|O_NOFOLLOW under
  // an unpredictable name in the images dir, fsync'd, size-checked, and then
  // renamed into place. rename() replaces a planted entry without ever
  // following it.
  readonly property string copyImagesScript:
    "while (( $# >= 2 )); do\n" +
    "  tmp=\"${2%/*}/copy.$$.$RANDOM$RANDOM.tmp\"\n" +
    "  if [[ -f $1 ]] && timeout 5 dd if=\"$1\" of=\"$tmp\" bs=65536 count=81 iflag=nonblock oflag=nofollow conv=excl,fsync status=none 2>/dev/null &&\n" +
    "     (( $(stat -c%s -- \"$tmp\") <= 5242880 )); then mv -f -- \"$tmp\" \"$2\"; else rm -f -- \"$tmp\"; fi\n" +
    "  shift 2\n" +
    "done\n"

  // Read every entry file in a state directory ($1) with hard ceilings:
  // at most 1100 files (history itself is clamped to 1000 by the widget)
  // and 32 KiB per file — snapshot-time text caps keep honest entries far
  // below that, so an over-limit file is hostile, gets truncated, fails to
  // parse, and drops. The aggregate reaching the StdioCollector is bounded
  // by the product. Every open is O_NOFOLLOW|O_NONBLOCK via dd: a planted
  // symlink is refused at open and a planted FIFO reads as an immediate
  // error instead of parking the long-lived shell. The printf after each
  // file keeps a torn file missing its newline from gluing onto the next
  // one (what `awk 1` did before).
  readonly property string readJsonDirScript:
    guardDirScript +
    "guard_dir \"$1\" || exit 0\n" +
    "n=0\n" +
    "for f in \"$1\"/*.json; do\n" +
    "  [[ -e $f ]] || continue\n" +
    "  (( ++n > 1100 )) && exit 0\n" +
    "  dd if=\"$f\" bs=32768 count=1 iflag=nofollow,nonblock status=none 2>/dev/null\n" +
    "  printf '\\n'\n" +
    "done\n" +
    "exit 0"

  function persistPopupFile(snapshot) {
    // The JSON travels as an argument, not through shell interpolation, so
    // summaries/bodies with quotes or backticks can't break the command. The
    // mkdir guards notifications that arrive before ensureDirsProc has run.
    // Copies run before the JSON referencing them, while the source exists.
    var persistable = NotificationLogic.persistablePopup(snapshot, imagesDir)
    var command = ["bash", "-c",
      "mkdir -p \"$1\" \"$2\" || exit 0\n" +
      guardDirScript +
      "guard_dir \"$1\" && guard_dir \"$2\" || exit 0\n" +
      "dir=\"$1\" json=\"$3\" name=\"$4\"\n" +
      "shift 4\n" +
      copyImagesScript +
      // Exclusive unpredictable temp, fsync, atomic rename — a planted
      // symlink or FIFO at the JSON's predictable name is never opened.
      "tmp=\"$dir/json.$$.$RANDOM$RANDOM.tmp\"\n" +
      "if printf '%s\\n' \"$json\" | dd of=\"$tmp\" bs=65536 oflag=nofollow conv=excl,fsync status=none 2>/dev/null; then\n" +
      "  mv -f -- \"$tmp\" \"$dir/$name\"\n" +
      "else rm -f -- \"$tmp\"; fi", "--",
      popupStateDir,
      imagesDir,
      NotificationLogic.serializePopup(persistable.entry, NotificationUrgency.Normal),
      NotificationLogic.popupFileName(snapshot)]
    for (var i = 0; i < persistable.copies.length; i++)
      command.push(persistable.copies[i].from, persistable.copies[i].to)
    enqueuePopupFileJob(command)
  }

  function deletePopupFileFor(row) {
    if (!row) return
    // History replays and the "no recent notifications" placeholder never
    // had a file — rm -f on the computed paths is a harmless no-op there.
    enqueuePopupFileJob(["bash", "-c",
      "rm -f \"$1/$2.json\" \"$3/$2\"-*", "--",
      popupStateDir, NotificationLogic.imageStem(row), imagesDir])
  }

  // ---------------------------------------------------- history
  //
  // A popup that leaves the screen keeps its file — it just moves one level
  // down, into historyDir. Trimming happens right there in the same shell
  // job: the names sort numerically by their leading millisecond timestamp,
  // so everything but the newest historyLimit files is the tail to drop,
  // image copies included. Callers set $hist, $limit and $imgs first.
  readonly property string trimHistoryScript:
    "ls -1 \"$hist\" 2>/dev/null | sort -n | head -n \"-$limit\" | while IFS= read -r stale; do rm -f \"$hist/$stale\" \"$imgs/${stale%.json}\"-*; done"

  function archivePopupFileFor(row) {
    if (!row) return
    // A history replay or the empty-history placeholder has no file to move;
    // the failed mv leaves the history untouched, trimming included. Image
    // copies stay put — live and archived entries share imagesDir.
    enqueuePopupFileJob(["bash", "-c",
      "mkdir -p \"$1\" || exit 0\n" +
      "hist=\"$1\" limit=\"$2\" imgs=\"$5\"\n" +
      "mv -f \"$4/$3\" \"$1/$3\" 2>/dev/null || exit 0\n" +
      trimHistoryScript, "--",
      historyDir,
      String(historyLimit),
      NotificationLogic.popupFileName(row),
      popupStateDir,
      imagesDir])
    historyMutated()
  }

  // Record a notification that never made it to the screen (DND silenced it),
  // straight into history. Same file format as an archived popup, so the
  // replay can't tell the two apart.
  //
  // A silenced notification is untracked the moment it arrives, so the server
  // has nothing left for a later replaces_id to replace and hands the sender a
  // fresh id instead. Every update from a chatty thread is therefore its own
  // notification here, and several can sit in the ten slots together — there
  // is no id to recognize them by, and guessing from app and summary would
  // merge genuinely separate messages.
  function writeHistoryFile(entry, done) {
    if (!entry) {
      if (done) done()
      return
    }
    var persistable = NotificationLogic.persistablePopup(entry, imagesDir)
    var command = ["bash", "-c",
      "mkdir -p \"$1\" \"$5\" || exit 0\n" +
      guardDirScript +
      "guard_dir \"$1\" && guard_dir \"$5\" || exit 0\n" +
      "hist=\"$1\" limit=\"$2\" name=\"$3\" json=\"$4\" imgs=\"$5\"\n" +
      "shift 5\n" +
      copyImagesScript +
      // Same exclusive-temp/rename discipline as persistPopupFile.
      "tmp=\"$hist/json.$$.$RANDOM$RANDOM.tmp\"\n" +
      "printf '%s\\n' \"$json\" | dd of=\"$tmp\" bs=65536 oflag=nofollow conv=excl,fsync status=none 2>/dev/null || { rm -f -- \"$tmp\"; exit 0; }\n" +
      "mv -f -- \"$tmp\" \"$hist/$name\" || exit 0\n" +
      trimHistoryScript, "--",
      historyDir,
      String(historyLimit),
      NotificationLogic.popupFileName(entry),
      NotificationLogic.serializePopup(persistable.entry, NotificationUrgency.Normal),
      imagesDir]
    for (var i = 0; i < persistable.copies.length; i++)
      command.push(persistable.copies[i].from, persistable.copies[i].to)
    enqueuePopupFileJob(command, done)
    historyMutated()
  }

  function clearHistory() {
    enqueuePopupFileJob(["bash", "-c",
      "for f in \"$1\"/*.json; do\n" +
      "  [[ -e $f ]] || continue\n" +
      "  stale=\"${f##*/}\"\n" +
      "  rm -f \"$f\" \"$2/${stale%.json}\"-*\n" +
      "done", "--", historyDir, imagesDir])
    // All panels share this model, so clearing it here empties every open
    // notification center at once; the rm above catches up on disk.
    historyModel.clear()
  }

  // ---------------------------------------------------- notification center
  //
  // The notification center panel (NotificationCenter.qml, the bar-widget
  // entry point of this plugin) renders history from this model rather than
  // replaying toasts. The model is owned here, beside the file queue, so
  // every monitor's panel shows the same rows and every read is ordered
  // after the mutation that made it necessary.

  property alias historyModel: historyModel
  ListModel { id: historyModel }

  // Fired when a file job that ADDS to historyDir has been queued (a toast
  // archived, a DND-silenced write). Removals mutate historyModel directly,
  // so they need no re-read. Panels listen while open and refresh; the read
  // joins the queue behind the mutation, so it always sees the result.
  signal historyMutated()

  // Set from the moment a model read is queued until it starts, so bursts
  // of historyMutated collapse into one directory read.
  property bool historyModelReadQueued: false

  function refreshHistoryModel() {
    if (historyModelProc.running || historyModelReadQueued) return
    historyModelReadQueued = true
    enqueueHistoryModelRead()
  }

  function startHistoryModelRead() {
    service.historyModelReadQueued = false
    historyModelProc.command = ["bash", "-c", readJsonDirScript, "--", historyDir]
    historyModelProc.running = true
  }

  function fillHistoryModel(raw) {
    var rows = NotificationLogic.historyRows(
      raw, [], NotificationUrgency.Normal, service.historyLimit)
    historyModel.clear()
    for (var i = 0; i < rows.length; i++) historyModel.append(rows[i])
  }

  // Remove a single entry from history: its model row, its JSON file, and
  // its image copies. Keyed by timestamp + originalId — the same identity
  // the file name carries — so it can't touch a neighboring entry.
  function deleteHistoryEntry(timestamp, originalId) {
    var stem = String(timestamp || 0) + "-" + String(originalId || 0)
    if (!/^[0-9]+-[0-9]+$/.test(stem)) return
    for (var i = historyModel.count - 1; i >= 0; i--) {
      var row = historyModel.get(i)
      if (row && row.timestamp === timestamp && row.originalId === originalId)
        historyModel.remove(i)
    }
    enqueuePopupFileJob(["bash", "-c",
      "rm -f \"$1/$3.json\" \"$2/$3\"-*", "--", historyDir, imagesDir, stem])
  }

  Process {
    id: historyModelProc
    running: false
    // Let the file queue go again whatever the read did, like readHistoryProc.
    onExited: service.runNextPopupFileJob()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: service.fillHistoryModel(text)
    }
  }

  // A restart can kill a queued job between its cp and its JSON write,
  // leaving copies no JSON-derived cleanup can name — and now also between
  // an exclusive temp's create and its rename. Swept at startup, through
  // the queue so in-flight files aren't mistaken for orphans. Temp names
  // are prefix-scoped so the sweep can't touch anything else in the shared
  // state dir.
  function sweepOrphanImages() {
    enqueuePopupFileJob(["bash", "-c",
      "rm -f -- \"$1\"/json.*.tmp \"$2\"/json.*.tmp \"$4\"/settings.*.tmp\n" +
      "for img in \"$3\"/*; do\n" +
      "  [[ -e $img ]] || continue\n" +
      "  [[ $img == *.tmp ]] && { rm -f -- \"$img\"; continue; }\n" +
      "  stem=\"${img##*/}\"\n" +
      "  stem=\"${stem%-*}\"\n" +
      "  [[ -e $1/$stem.json || -e $2/$stem.json ]] || rm -f \"$img\"\n" +
      "done", "--", popupStateDir, historyDir, imagesDir, stateDir])
  }

  Process {
    id: readHistoryProc
    running: false
    // Let the file queue go again, whatever the read did — a failed or empty
    // read must not leave archives and clears parked behind it forever.
    onExited: service.runNextPopupFileJob()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: service.replayHistory(text)
    }
  }

  // Toasts that were on screen when the replay was asked for. The clear in
  // replayHistory archives them, but the directory read is already in flight
  // by then, so they're handed over in memory instead of being waited for.
  property var replayCarryOver: []

  // Set from the moment a read is queued until it starts, so a second
  // showHistory while one is still waiting its turn doesn't queue another.
  property bool historyReadQueued: false

  // Re-show what's in historyDir as toasts. The read goes through the file
  // queue and its own subprocess, so the replay lands in replayHistory once
  // the work queued ahead of it has finished.
  function showRecentHistory() {
    if (readHistoryProc.running || service.historyReadQueued) return "ok"
    service.replayCarryOver = liveRowsForReplay()
    service.historyReadQueued = true
    enqueueHistoryRead()
    return "ok"
  }

  function startHistoryRead() {
    service.historyReadQueued = false
    readHistoryProc.command = ["bash", "-c", readJsonDirScript, "--", historyDir]
    readHistoryProc.running = true
  }

  // Copy the on-screen rows out of the model. The placeholder from an earlier
  // empty replay carries originalId -1 and is not a notification, so it is
  // left behind rather than replayed as one. The replay dismisses these
  // notifications, and senders delete their images on close — so the carried
  // rows point at the persisted copies, like the archived files they join.
  function liveRowsForReplay() {
    var rows = []
    for (var i = 0; i < popupModel.count; i++) {
      var row = popupModel.get(i)
      if (!row || row.originalId < 0) continue
      rows.push(NotificationLogic.persistablePopup({
        id: row.id,
        originalId: row.originalId,
        app: row.app,
        appIcon: row.appIcon,
        summary: row.summary,
        body: row.body,
        image: row.image,
        glyph: row.glyph || "",
        execArgv: row.execArgv || "",
        urgency: row.urgency,
        timestamp: row.timestamp
      }, imagesDir).entry)
    }
    return rows
  }

  function replayHistory(raw) {
    var rows = NotificationLogic.historyRows(
      raw, service.replayCarryOver, NotificationUrgency.Normal, service.replayLimit)
    service.replayCarryOver = []

    // Replaying nothing at all looks like a dead keybinding, so say so.
    if (rows.length === 0) {
      popupModel.insert(0, {
        id: -1,
        originalId: -1,
        app: "omarchy-action",
        appIcon: "",
        summary: "No recent notifications",
        body: "",
        image: "",
        glyph: "󰂚",
        execArgv: "",
        urgency: NotificationUrgency.Low,
        expireTimeout: 0,
        timestamp: Date.now()
      })
      return
    }

    clearPopups()
    // Rows arrive newest-first, and index 0 is the top of the toast stack.
    for (var i = 0; i < rows.length; i++) {
      // Replayed rows are restored rows: their notification died with the
      // sender long ago, so they must never resolve to a live server object
      // that has since been handed their old id.
      service.restoredPopups[NotificationLogic.popupFileName(rows[i])] = true
      popupModel.append(rows[i])
    }
  }

  Process {
    id: restorePopupsProc
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: service.restorePopups(text)
    }
  }

  function restorePopups(raw) {
    var entries = NotificationLogic.parsePopupFiles(raw, NotificationUrgency.Normal)
    var now = Date.now()
    var live = []
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i]
      var duration = durationFor(entry.urgency, entry.expireTimeout)
      if (NotificationLogic.popupExpired(entry, duration, now)) {
        // It would have expired on screen had the shell kept running, so it
        // gets archived exactly like an expiry that happened while it did.
        archivePopupFileFor(entry)
        continue
      }
      // Survivors restart with a full lifetime on purpose: shell restarts
      // are rare, and a full look after the restart flicker beats resuming
      // a toast with a second left on its clock. The reset is persisted as
      // an absolute deadline so a second restart while the toast is still
      // on screen judges it by the reset clock, not the original timestamp.
      if (duration > 0) {
        entry.deadline = now + duration
        persistPopupFile(entry)
        // deadline is persistence metadata, not a model role — fresh rows
        // never carry it, and ListModel roles must stay consistent.
        delete entry.deadline
      }
      live.push(entry)
    }
    if (live.length === 0) return

    Qt.callLater(function() {
      for (var j = 0; j < live.length; j++) {
        var restored = live[j]
        // A notification received while the restore was reading the dir can
        // already occupy this originalId with the same timestamp — then it
        // IS this entry, live with its own file, and must be left alone. A
        // different timestamp is indistinguishable between a genuine
        // cross-restart replaces_id and a new-generation id coincidence, so
        // show both: a briefly duplicated toast beats silently dropping a
        // restored critical alert.
        var duplicate = false
        for (var k = 0; k < popupModel.count; k++) {
          var row = popupModel.get(k)
          if (row && row.originalId === restored.originalId && row.timestamp === restored.timestamp) {
            duplicate = true
            break
          }
        }
        if (duplicate) continue
        // Append (entries are newest-first) so restored toasts stack in
        // their original order below anything that just arrived. Restored
        // popups have no liveRefs entry — the server object died with the
        // old shell — so dismissal and action fallbacks degrade gracefully.
        service.restoredPopups[NotificationLogic.popupFileName(restored)] = true
        popupModel.append(restored)
      }
    })
  }

  // ---------------------------------------------------- settings persistence

  // Settings go through the same hardened I/O as every other state file —
  // FileView would open the predictable path directly, following a planted
  // symlink or parking its read on a planted FIFO. A missing file (first
  // run) reads as empty output, which loadSettings handles.
  Process {
    id: settingsReadProc
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: service.loadSettings(text)
    }
  }

  function startSettingsRead() {
    settingsReadProc.command = ["bash", "-c",
      guardDirScript +
      "guard_dir \"$1\" || exit 0\n" +
      "dd if=\"$2\" bs=65536 count=1 iflag=nofollow,nonblock status=none 2>/dev/null\n" +
      "exit 0", "--", stateDir, settingsPath]
    settingsReadProc.running = true
  }

  Timer {
    id: settingsSaveTimer
    interval: 200
    repeat: false
    onTriggered: service.flushSettings()
  }

  function scheduleSettingsSave() {
    if (!service.settingsLoaded) return
    settingsSaveTimer.restart()
  }

  property bool settingsLoaded: false

  function loadSettings(raw) {
    // Guard against ever being called twice — hydration must not run again
    // once a later save could be in flight.
    if (service.settingsLoaded) return

    var parsed = NotificationLogic.parseSettings(raw)
    if (parsed.error) console.warn("notifications: settings parse failed:", parsed.errorMessage || "")

    if (parsed.dnd !== null) {
      service._hydrating = true
      persisted.doNotDisturb = parsed.dnd
      service._hydrating = false
    }

    service.settingsLoaded = true
    // Versions before the history moved into its own directory kept every
    // notification in here. Rewrite once so that dead payload doesn't sit in
    // the file until the next DND toggle happens to clear it.
    if (parsed.legacy) service.scheduleSettingsSave()
  }

  function flushSettings() {
    // Through the serialized queue with the exclusive-temp/rename discipline:
    // the settings file's predictable name is only ever the target of a
    // rename, never of an open. The temp lands in the shared omarchy state
    // dir, so it carries a recognizable prefix for the startup sweep.
    enqueuePopupFileJob(["bash", "-c",
      guardDirScript +
      "guard_dir \"$1\" || exit 0\n" +
      "tmp=\"$1/settings.$$.$RANDOM$RANDOM.tmp\"\n" +
      "if printf '%s\\n' \"$3\" | dd of=\"$tmp\" bs=65536 oflag=nofollow conv=excl,fsync status=none 2>/dev/null; then\n" +
      "  mv -f -- \"$tmp\" \"$2\"\n" +
      "else rm -f -- \"$tmp\"; fi", "--",
      stateDir, settingsPath,
      JSON.stringify({ version: 3, dnd: persisted.doNotDisturb }, null, 2)])
  }

  Component.onCompleted: {
    ensureDirsProc.running = true
    // Once mkdir has had a tick, load the existing settings file. The
    // bounded read surfaces an empty string when the file doesn't exist;
    // loadSettings handles that path.
    Qt.callLater(function() {
      startSettingsRead()
      // Re-show popups that were on screen when the previous shell died.
      // The bounded reader tolerates a missing/empty dir (first run) and
      // keeps torn, planted, or oversized files from reaching the parser.
      restorePopupsProc.command = ["bash", "-c", service.readJsonDirScript, "--", service.popupStateDir]
      restorePopupsProc.running = true
      // Safe beside the restore read: it only re-persists entries whose
      // JSON exists, exactly the images the sweep keeps.
      service.sweepOrphanImages()
    })
  }

  // ---------------------------------------------------- IPC

  IpcHandler {
    target: "notifications"

    function dndState(): string {
      return service.doNotDisturb ? "on" : "off"
    }

    function toggleDnd(): string {
      service.setDoNotDisturb(!service.doNotDisturb)
      return dndState()
    }

    function setDnd(value: string): string {
      var v = String(value || "").toLowerCase()
      var on = v === "true" || v === "1" || v === "on" || v === "yes"
      service.setDoNotDisturb(on)
      return dndState()
    }

    function isDnd(): string {
      return dndState()
    }

    // Replay the notifications that have been moved into the history dir.
    function showHistory(): string {
      return service.showRecentHistory()
    }

    // `clear` forgets the recorded history; the toasts on screen stay put.
    function clear(): string {
      service.clearHistory()
      return "ok"
    }

    // Remove one history entry by its file stem (timestamp-id, the file
    // name without .json). Same path the notification center's per-card ✕
    // takes; exposed here so scripts can drop a single entry too.
    function removeHistory(stem: string): string {
      var parts = String(stem || "").split("-")
      if (parts.length !== 2) return "bad-stem"
      service.deleteHistoryEntry(Number(parts[0]), Number(parts[1]))
      return "ok"
    }

    function dismissAll(): string {
      service.clearPopups()
      return "ok"
    }

    // Dismiss the most recent popup.
    function dismissOne(): string {
      if (popupModel.count === 0) return "none"
      service.dismissPopup(0)
      return "ok"
    }

    // Fire the default action on the most recent popup, then dismiss it.
    function invokeLast(): string {
      if (popupModel.count === 0) return "none"
      service.invokePopupDefault(0)
      return "ok"
    }

    // Take a toast off the screen by summary substring, used by the
    // first-run notifications once their action has been clicked.
    function dismiss(summary: string): string {
      var needle = String(summary || "")
      if (!needle) return "none"
      var hit = false
      for (var i = popupModel.count - 1; i >= 0; i--) {
        var row = popupModel.get(i)
        if (row && String(row.summary || "").indexOf(needle) !== -1) {
          service.dismissPopup(i)
          hit = true
        }
      }
      return hit ? "ok" : "none"
    }

    function ping(): string { return "ok" }
  }

  // ---------------------------------------------------- server

  NotificationServer {
    id: server
    keepOnReload: false
    imageSupported: true
    actionsSupported: true
    bodyMarkupSupported: true
    bodyHyperlinksSupported: true
    persistenceSupported: true

    onNotification: function(notification) {
      service.handleNotification(notification)
    }
  }

  // -------------------------------------------------------------- popup UI
  //
  // One PanelWindow per output (Variants on Quickshell.screens) holding the
  // stacked toast cards. Layer is Overlay, exclusionMode Ignore, no
  // keyboard focus — popups are passive surfaces and must never steal input
  // from the focused application.

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: popupWindow
      required property var modelData
      screen: modelData
      visible: popupModel.count > 0

      WlrLayershell.namespace: "omarchy-notifications"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore
      color: "transparent"

      readonly property var popupPlacement: NotificationLogic.popupPlacement(
        service.barPosition, service.barClearance, Style.gapsOut)

      // Full-screen, fixed-size surface (like the OSD overlay). Adding or
      // removing a toast changes only the content inside; the Wayland surface
      // never resizes, so the compositor can't briefly scale a stale buffer --
      // which is what stretched/squished the cards during count changes.
      anchors { top: true; bottom: true; left: true; right: true }

      // Keep the surface click-through except over the toast column, so the
      // rest of the (invisible) full-screen overlay never eats input.
      mask: Region { item: popupColumn }

      ColumnLayout {
        id: popupColumn
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: popupWindow.popupPlacement.margins.top
        spacing: Style.space(8)

        Repeater {
          model: popupModel

          // The delegate is a slot Item that owns lifetime timer state. The
          // actual visuals live in NotificationCard, which the history panel
          // also reuses.
          delegate: Item {
            id: cardSlot
            required property int index
            required property string app
            required property string appIcon
            required property string summary
            required property string body
            required property string image
            required property string glyph
            required property int urgency
            required property double expireTimeout
            required property double timestamp

            // Each card sizes itself based on mode (text vs media); the slot
            // tracks the card so the column auto-fits to whichever is widest.
            Layout.preferredWidth: card.implicitWidth
            Layout.alignment: Qt.AlignHCenter
            implicitHeight: card.implicitHeight

            property real entranceOffset: -Style.space(28)
            property real entranceOpacity: 0
            Component.onCompleted: {
              entranceOffset = 0
              entranceOpacity = 1
            }

            Behavior on entranceOffset {
              NumberAnimation { duration: 300; easing.type: Easing.OutCubic }
            }
            Behavior on entranceOpacity {
              NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
            }

            readonly property real lifetime: service.durationFor(cardSlot.urgency, cardSlot.expireTimeout)
            property real remainingLifetime: 1.0
            readonly property bool ticking: cardSlot.lifetime > 0 && !card.hovered

            // A client updating this notification in place rewrites the row
            // under the card (see refreshPopup). New text deserves a full look,
            // so the countdown starts over instead of running out the clock the
            // superseded text was already most of the way through. Delegates
            // keep their own row as the model changes around them, so only a
            // real content change lands here.
            onSummaryChanged: cardSlot.remainingLifetime = 1.0
            onBodyChanged: cardSlot.remainingLifetime = 1.0
            onImageChanged: cardSlot.remainingLifetime = 1.0

            Timer {
              interval: 50
              repeat: true
              running: cardSlot.ticking
              onTriggered: {
                if (cardSlot.lifetime <= 0) return
                cardSlot.remainingLifetime -= 50.0 / cardSlot.lifetime
                if (cardSlot.remainingLifetime <= 0) {
                  cardSlot.remainingLifetime = 0
                  service.expirePopup(cardSlot.index)
                }
              }
            }

            NotificationCard {
              id: card
              anchors.horizontalCenter: parent.horizontalCenter
              opacity: cardSlot.entranceOpacity
              transform: Translate { y: cardSlot.entranceOffset }
              app: cardSlot.app
              appIcon: cardSlot.appIcon
              summary: cardSlot.summary
              body: cardSlot.body
              image: cardSlot.image
              urgency: cardSlot.urgency
              timestamp: cardSlot.timestamp
              cornerRadius: service.cornerRadius
              fontFamily: service.shell && service.shell.bar ? service.shell.bar.fontFamily : ""
              glyph: cardSlot.glyph

              onCloseRequested: service.dismissPopup(cardSlot.index)
              onCardClicked: service.invokePopupDefault(cardSlot.index)
            }
          }
        }
      }
    }
  }
}
