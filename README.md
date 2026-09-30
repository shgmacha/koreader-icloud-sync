# KOReader ⇄ iCloud Drive Sync

Keep a folder in iCloud Drive and a folder on your Kindle's KOReader in two-way sync.

- Drop a book into **iCloud Drive → KOReader** (from your iPhone, iPad or Mac) and it shows up in KOReader under **Books** (the `Books` folder at the Kindle root).
- Add or delete a book in that folder on the Kindle and iCloud follows.
- Highlights, notes, bookmarks and reading progress (KOReader's `.sdr` folders) are copied to iCloud too.

```
 iPhone / iPad / Mac ──iCloud──▶ Mac: iCloud Drive/KOReader
                                      │  icloud_bridge.py (HTTP, your Wi-Fi only)
                                      ▼
                               Kindle: KOReader plugin ⇄ /mnt/us/Books
```

A Kindle can't sign in to iCloud (there's no public iCloud Drive API, and Apple sign-in needs 2FA). Your Mac already has iCloud Drive on disk, so a tiny bridge on the Mac shares that one folder with the Kindle over your home Wi-Fi.

**Syncing needs the Mac to be awake and on the same Wi-Fi as the Kindle.** Otherwise the plugin just waits for the next chance.

## 1. Set up the Mac

```bash
cd koreader-icloud-sync
./bridge/install.sh
```

This:
- creates `iCloud Drive/KOReader/`
- writes `~/.config/koreader-icloud-bridge/config.json` with a random token
- installs a login agent so the bridge starts automatically (`~/Library/LaunchAgents/com.koreader.icloudbridge.plist`)
- prints the **server address** and **token** to type into KOReader

If macOS asks whether `python3` may accept incoming network connections, click **Allow**.

**Full Disk Access (one time):** macOS blocks background programs from iCloud Drive. The installer creates a small app, `~/Applications/KOReader iCloud Bridge.app`, which runs the bridge. The first time, the installer opens the Full Disk Access settings and a Finder window showing the app. Drag the app into the list (or click **+**, press ⌘⇧G, type `~/Applications`, and choose it), turn it on, then run `install.sh` again. It should finish with ✅.

**Tip:** reserve the Mac's IP address in your router (DHCP reservation) so it doesn't change.

To remove it: `./bridge/uninstall.sh` (your iCloud folder is untouched).

## 2. Install the plugin on the Kindle

1. Connect the Kindle by USB.
2. Copy the `icloudsync.koplugin` folder into `koreader/plugins/` on the Kindle.
3. Eject, restart KOReader.
4. Open **Tools (🛠) → iCloud Sync**:
   - **Server address** → e.g. `192.168.1.20:8765` (from `install.sh`)
   - **Token** → the token from `install.sh`
   - **Test connection** → should say "Connected".
   - **Sync now**.

## How it behaves

| When | What happens |
|------|--------------|
| Wi-Fi connects | Syncs automatically (at most every 5 minutes). A small notification appears only if something changed. |
| Kindle wakes up (if Wi-Fi is already on) | Same as above. |
| **Tools → iCloud Sync → Sync now** | Syncs and shows a summary. You can also assign this to a gesture (Gesture manager → General → *iCloud Sync: sync now*). |

- **Conflicts:** if the same file changed on both sides, the newer one wins.
- **Edit vs delete:** if one side deleted a file and the other edited it, the edited file comes back.
- **Deleting on the Kindle** moves the file into a hidden `iCloud Drive/KOReader/.koreader-trash/<date>/` folder on the Mac. Nothing is permanently deleted there. (In Finder, press ⌘⇧. to show hidden folders.)
- **Safety brake:** if a single sync would delete more than 10 files *and* more than half of everything synced, nothing is deleted and you're asked first. This protects you if the iCloud folder gets renamed or the Kindle folder gets wiped.
- **The book you're reading** (and its highlights) is skipped until you close it; it syncs next time.
- **Files still in the cloud:** with "Optimize Mac Storage" on, iCloud may keep some files only in the cloud. The bridge asks macOS to download them, and they sync on a later run.

### Highlights & progress

These sync only if KOReader stores them next to the book, which is the default: **Settings → Document → Book metadata location → "book folder"**. The plugin tells you if that setting is different.

If you read the same book on two KOReader devices, the newest `.sdr` folder wins as a whole; highlights aren't merged.

### What syncs

- Books: `epub pdf mobi azw azw3 fb2 cbz cbr djvu txt rtf docx html md`
- Everything inside `*.sdr` folders except `*.old` backups
- Subfolders, both ways
- Skipped: hidden files, and names containing `: * ? " < > | \` (not allowed on Kindle storage)

## Troubleshooting

| Problem | Fix |
|---------|-----|
| "Mac bridge not reachable" | Is the Mac awake and on the same Wi-Fi? Run `curl http://<mac-ip>:8765/health` from another device. Check the macOS firewall allowed `python3`. |
| "Bad token" | Re-enter the token. It's stored in `~/.config/koreader-icloud-bridge/config.json`. |
| "cannot read sync folder" | Give **KOReader iCloud Bridge** Full Disk Access (see setup), then re-run `install.sh`. |
| Nothing happens automatically | Check **Auto-sync when Wi-Fi connects** is ticked. Auto-sync waits 5 minutes between runs. Use **Sync now** to force it. |
| Bridge log | `~/Library/Logs/koreader-icloud-bridge.log` |
| Kindle log | `koreader/crash.log` (search for `icloudsync`) |

## Security

The bridge only listens on your local network, requires the token for everything except `/health`, only serves and accepts book and `.sdr` files inside the one folder, and never permanently deletes anything. Traffic is plain HTTP (not encrypted), so don't use it on untrusted Wi-Fi.

## Development

```bash
/usr/bin/python3 -m unittest discover -s bridge -v   # bridge
luajit tests/test_syncplan.lua                         # reconciliation rules
luajit tests/test_syncengine.lua                       # sync engine (fake Mac + Kindle)
luajit tests/test_plugin_load.lua                      # plugin wiring (stubbed KOReader)
```

Run the bridge by hand against any folder:

```bash
/usr/bin/python3 bridge/icloud_bridge.py --root /tmp/books --token test --port 8765
```
