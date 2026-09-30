# 📚 iCloud Sync for KOReader

**Drop a book into iCloud Drive and it appears on your Kindle. Read, highlight, add or delete books on your Kindle, and iCloud stays up to date.**

A two-way sync between your Kindle's `Books` folder (in [KOReader](https://koreader.rocks)) and a folder in your iCloud Drive: books, highlights, notes and reading progress.

[**⬇️ Download the latest release**](https://github.com/shgmacha/koreader-icloud-sync/releases/latest)

```
 iPhone / iPad / Mac ──iCloud──▶ Mac: iCloud Drive/KOReader
                                        │  (home Wi-Fi)
                                        ▼
                                 Kindle: Books folder
```

---

## Contents

- [What you need](#-what-you-need)
- [Setup (about 5 minutes)](#-setup-about-5-minutes)
- [Using it](#-using-it)
- [FAQ](#-faq)
- [Troubleshooting](#-troubleshooting)
- [Updating & uninstalling](#-updating--uninstalling)

---

## ✅ What you need

- A **Kindle with KOReader** installed
- A **Mac** signed in to iCloud with **iCloud Drive** turned on
- The Mac and the Kindle on the **same Wi-Fi**

> **Why does the Mac need to be involved?** A Kindle can't sign in to iCloud: Apple doesn't offer an iCloud Drive API, and sign-in needs a two-factor code. Your Mac already has iCloud Drive, so a tiny helper app on the Mac (the "bridge") shares one folder with your Kindle over your home Wi-Fi.

---

## 🚀 Setup (about 5 minutes)

### Step 1: Set up your Mac

Open **Terminal** (press ⌘ Space, type `Terminal`, press Return) and paste these lines one at a time.

1. **Install Apple's developer tools** (skip this if you've done it before; a window pops up, click **Install**):
   ```bash
   xcode-select --install
   ```

2. **Download this project:**
   ```bash
   git clone https://github.com/shgmacha/koreader-icloud-sync.git ~/koreader-icloud-sync
   ```

3. **Run the installer:**
   ```bash
   ~/koreader-icloud-sync/bridge/install.sh
   ```

When it finishes you'll see something like:

```
✅ Bridge running and can read: …/iCloud Drive/KOReader

Enter these in KOReader → Tools → iCloud Sync:
   Server address:  192.168.1.20:8765
   Token:           3f9c…
```

📝 **Keep this window open.** You'll type the server address and token into your Kindle in Step 3.

<details>
<summary>⚠️ It says "Operation not permitted" instead of ✅</summary>

macOS sometimes blocks background apps from reading iCloud Drive. The installer opens the right settings for you:

1. In **System Settings → Privacy & Security → Full Disk Access**, click **+**.
2. Press **⌘ Shift G**, type `~/Applications`, and choose **KOReader iCloud Bridge**.
3. Make sure its switch is **on**.
4. Run the installer again (step 3 above). It should now finish with ✅.

</details>

<details>
<summary>💬 macOS asks whether to "accept incoming network connections"</summary>

Click **Allow**. That's how your Kindle reaches the Mac.

</details>

### Step 2: Install the plugin on your Kindle

1. Download **`icloudsync.koplugin.zip`** from the [latest release](https://github.com/shgmacha/koreader-icloud-sync/releases/latest) and unzip it.
2. Plug your Kindle into your Mac with a USB cable.
3. Copy the **`icloudsync.koplugin`** folder into **`koreader/plugins/`** on the Kindle.
   It should end up as `koreader/plugins/icloudsync.koplugin/main.lua`, not one folder deeper.
4. Eject the Kindle and **restart KOReader**.

### Step 3: Connect them

1. In KOReader, tap the **top of the screen** to open the menu.
2. Tap the **🛠 Tools** icon. **iCloud Sync** is at the bottom of the list (you may need the next page).
3. Tap **Server address** and enter the address from Step 1 (e.g. `192.168.1.20:8765`).
4. Tap **Token** and enter the token from Step 1.
5. Tap **Test connection**. You should see **"Connected"** 🎉
6. Tap **Sync now**.

That's it! Your Kindle's `Books` folder and **iCloud Drive → KOReader** are now linked.

---

## 📖 Using it

### Adding books

| From | Do this |
|------|---------|
| iPhone / iPad | **Files** app → **iCloud Drive → KOReader** → save or move the book there |
| Mac | Drag the book into **iCloud Drive → KOReader** in Finder |
| Kindle | Put the book in the `Books` folder. It's uploaded to iCloud on the next sync |

Subfolders work too, so you can organise by author or series.

### When does it sync?

- 📶 **When your Kindle connects to Wi-Fi**
- 💤 **When your Kindle wakes up** (if Wi-Fi is already on)
- 👆 **Whenever you tap** **Tools → iCloud Sync → Sync now**

Automatic syncs happen at most every 5 minutes, and only show a small notification when something actually changed.

> 💡 **Tip:** add a gesture for it in **Settings → Taps and gestures → Gesture manager**. Look for **iCloud Sync: sync now** under **General**.

### What gets synced

- 📚 **Books:** EPUB, PDF, MOBI, AZW, AZW3, FB2, CBZ, CBR, DJVU, TXT, RTF, DOCX, HTML, MD
- 🖍️ **Highlights, notes, bookmarks and reading progress**, so they're backed up to iCloud too
- 📁 **Subfolders**, in both directions

### Settings

In **Tools → iCloud Sync** you can turn each automatic sync on or off, change the server address or token, test the connection, and see when the last sync happened.

---

## ❓ FAQ

<details>
<summary><b>What happens if I delete a book?</b></summary>

It's deleted on the other side too, on the next sync, but nothing is ever lost on your Mac. Books deleted from the Kindle are moved to a hidden **`.koreader-trash`** folder inside **iCloud Drive → KOReader**, sorted by date. To see it in Finder, press **⌘ Shift .** (period).

</details>

<details>
<summary><b>What if I change the same book in two places?</b></summary>

The most recent change wins. If a book was edited on one side and deleted on the other, the edited copy is kept.

</details>

<details>
<summary><b>Could a mistake wipe my library?</b></summary>

There's a safety brake: if a single sync would delete more than half of your synced books (for example, because a folder was renamed), it stops and asks you before deleting anything.

</details>

<details>
<summary><b>What about the book I'm reading right now?</b></summary>

It's left alone until you close it, so the sync never pulls a book out from under you. It catches up on the next sync.

</details>

<details>
<summary><b>Does my Mac have to be on?</b></summary>

Yes: the Mac must be awake and on the same Wi-Fi as your Kindle. If it isn't, nothing breaks: the Kindle simply syncs next time it can reach the Mac. The helper starts by itself when you log in to your Mac.

</details>

<details>
<summary><b>My highlights aren't showing up in iCloud</b></summary>

KOReader needs to keep them next to the book, which is the default. Check **Settings → Document → Book metadata location** is set to **book folder**. The plugin warns you if it isn't.

</details>

<details>
<summary><b>Some books are "still downloading to the Mac"</b></summary>

With **Optimize Mac Storage** on, iCloud keeps some files only in the cloud. The helper asks your Mac to download them, and they sync on a later run. Nothing to do.

</details>

<details>
<summary><b>A new book doesn't appear in my library view</b></summary>

KOReader (and the Bookshelf plugin) only show books inside your **home folder**. Long-press the 🏠 icon in the file browser and set it to `/mnt/us/Books` or `/mnt/us`. The plugin tells you if the `Books` folder is outside your home folder.

</details>

<details>
<summary><b>Is it secure?</b></summary>

The helper only works on your local network, needs your private token, and can only read and write book files inside that one iCloud folder. It never permanently deletes anything. The connection isn't encrypted, so use it on your home Wi-Fi, not on public Wi-Fi.

</details>

<details>
<summary><b>Do I need to keep the Terminal window open?</b></summary>

No. Once the installer shows ✅, the helper runs in the background and starts automatically every time you log in.

</details>

---

## 🛠 Troubleshooting

| You see… | Try this |
|----------|----------|
| **"Mac bridge not reachable"** | Make sure the Mac is awake and on the same Wi-Fi. If you clicked **Don't Allow** on a network prompt, allow it in **System Settings → Network → Firewall → Options**. |
| **"Bad token"** | Re-enter the token. To see it again, run the installer again; it keeps the same token. |
| **"cannot read sync folder: Operation not permitted"** | Give **KOReader iCloud Bridge** Full Disk Access. See [Step 1](#step-1-set-up-your-mac). |
| **"Set the server address and token first"** | Fill in both under **Tools → iCloud Sync**. |
| **iCloud Sync isn't in the Tools menu** | Check the folder is at `koreader/plugins/icloudsync.koplugin/main.lua`, and that it's ticked in **Tools → More tools → Plugin management**. |
| **Nothing syncs automatically** | Check the auto-sync options are ticked. Automatic syncs wait 5 minutes between runs; **Sync now** always works. |
| **The Mac's address keeps changing** | Give your Mac a fixed address in your router's settings (often called a "DHCP reservation"), or re-run the installer to see the new one. |

Still stuck? [Open an issue](https://github.com/shgmacha/koreader-icloud-sync/issues) and include the last lines of:
- Mac: `~/Library/Logs/koreader-icloud-bridge.log`
- Kindle: `koreader/crash.log` (lines mentioning `icloudsync`)

---

## 🔄 Updating & uninstalling

**Update:**
```bash
cd ~/koreader-icloud-sync && git pull && ./bridge/install.sh
```
Then copy the new `icloudsync.koplugin` folder from the [latest release](https://github.com/shgmacha/koreader-icloud-sync/releases/latest) to your Kindle. Your settings and token are kept.

**Uninstall:**
```bash
~/koreader-icloud-sync/bridge/uninstall.sh
```
Then delete `koreader/plugins/icloudsync.koplugin` from your Kindle. Your books in iCloud and on the Kindle are **not** touched.

---

<details>
<summary>🔧 How it works & development</summary>

### Architecture

- **`bridge/icloud_bridge.py`**: a small HTTP server (Python standard library only) that serves `iCloud Drive/KOReader` on port 8765, protected by a token. It's run at login by a launch agent through a tiny app, `~/Applications/KOReader iCloud Bridge.app`, so macOS privacy permissions apply to a named app.
- **`icloudsync.koplugin/`**: the KOReader plugin. For each file it compares iCloud, the Kindle, and what both looked like at the last sync, then decides whether to download, upload, delete or leave it alone.

Endpoints: `GET /health`, `GET /manifest`, `GET|PUT|DELETE /file/<path>`.

### What syncs, precisely

- Book files with the extensions listed above, plus everything inside `*.sdr` folders except `*.old` backups
- Skipped: hidden files, and names containing `: * ? " < > | \` (not allowed on Kindle storage)

### Running the tests

```bash
/usr/bin/python3 -m unittest discover -s bridge -v   # bridge
luajit tests/test_syncplan.lua                         # sync rules
luajit tests/test_syncengine.lua                       # sync engine (simulated Mac + Kindle)
luajit tests/test_plugin_load.lua                      # plugin wiring (stubbed KOReader)
```

Run the bridge by hand against any folder:

```bash
/usr/bin/python3 bridge/icloud_bridge.py --root /tmp/books --token test --port 8765
```

</details>

---

MIT License · Made for readers who live in iCloud 📖
