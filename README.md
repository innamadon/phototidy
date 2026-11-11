# Photo Tidy

An iPhone app that finds look-alike photos, picks the best shot in each group, and helps you delete the rest. Everything runs on the phone; no photos are uploaded anywhere.

This guide is for **Windows, with no Mac**: GitHub builds the app for free, and AltStore installs it and keeps it working over Wi-Fi.

---

## Part 1 — Let GitHub build the app (about 10 minutes, one time)

1. Create a free account at **github.com** if you don't have one.
2. Click **+ → New repository**. Name it `photo-tidy`. Choose **Public** (unlimited free builds) or **Private** (roughly 30 free builds a month). Click **Create repository**.
3. On the next page, click **uploading an existing file**.
4. Unzip `PhotoTidy.zip` on your PC. Open the `PhotoTidy` folder, select **everything inside it** (`.github`, `PhotoTidy`, `PhotoTidy.xcodeproj`, `README.md`) and drag it all into the browser. Click **Commit changes**.
5. Open the **Actions** tab. A run called **Build iPhone app** starts by itself and takes about 5 minutes.
   - If Actions shows nothing, the hidden `.github` folder didn't upload. Click **Add file → Create new file**, type `.github/workflows/build.yml` as the name, paste in the contents of that file from the zip, and commit.
6. When the run has a green tick, go to the repository's main page → **Releases** (right side) → **Latest build** → download **PhotoTidy.ipa**. You can download it on the PC or straight onto the iPhone in Safari.

**If the run has a red X:** click the run, and the summary page shows a box titled "Build failed". Copy what's in the box and send it to Claude; the fix is usually a one-line change.

**Updating later:** replace the changed files in the repository (Add file → Upload files). GitHub rebuilds automatically and the Latest build is replaced.

---

## Part 2 — Install on the iPhone with AltStore (about 20 minutes, one time)

Apple's free accounts make self-installed apps expire after 7 days. AltStore renews the app for you over Wi-Fi, so you only plug in once.

1. On the PC, install **iTunes** and **iCloud** downloaded **directly from Apple's website** (not the Microsoft Store versions).
2. Install **AltServer** from **altstore.io** and follow its Windows guide: https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows
3. Plug in the iPhone, tap **Trust**, and in iTunes turn on **Sync with this iPhone over Wi-Fi**.
4. On the iPhone, turn on **Settings → Privacy & Security → Developer Mode** (the phone restarts).
5. On the PC, click the AltServer icon in the system tray → **Install AltStore** → your iPhone. Sign in with your Apple ID when asked.
6. On the iPhone, go to **Settings → General → VPN & Device Management**, tap your Apple ID, and tap **Trust**.
7. Open **AltStore** on the iPhone → **My Apps** → **+** → choose **PhotoTidy.ipa** (from Files/Downloads).
8. Open **Photo Tidy**, tap **Allow Photo Access**, and choose **Allow Full Access**.

**Keeping it working without plugging in:** leave AltServer running on the PC. Whenever the phone and PC are on the same Wi-Fi, AltStore renews the app in the background. If it ever shows fewer than 2 days left, open AltStore and tap **Refresh All**.

Things to know:
- A free Apple ID can have 3 self-installed apps at a time; AltStore itself is one of them.
- **SideStore** (sidestore.io) is a variant that renews on the phone with no PC at all after setup. Setup is fiddlier; the same PhotoTidy.ipa works with it.
- If the app does expire, nothing is lost. Refresh it and it opens again.

---

## Using the app

The floating bar at the bottom has four tabs and a Settings button. Each tab has small pills at the top to switch between its parts.

**Similar** — look-alike photos
1. Tap **Find look-alikes**. Groups ("moments") appear while it scans, newest first. Keep the app open during a scan.
2. Tap **Review one by one**. In each group the suggested keeper is on top, marked **Best**.
   - Tap a photo to switch it between keep and let go.
   - Tap the corner arrows to compare full screen: pinch to zoom, hold **Hold for Best** to flip to the best shot, and turn on **Focus check** to see what's truly sharp.
   - Tap **Looks good — next** to move on.
3. Back on Similar, tap **Delete … extras**. iOS asks once to confirm.

**Clutter**
- **Blurry:** photos where nothing is in focus. Photos with people are kept (switch this in Settings). The Fewer / More slider decides how soft a photo must be to show up. Favorites are never suggested.
- **Duplicates:** identical copies of the same photo, including ones re-saved smaller by a messaging app. The best copy is kept; the rest are marked.
- **Screenshots:** oldest first, with an age filter.
- **Receipts:** finds photos of receipts and marks them. **File** adds them to a **Receipts** album and sends them to your receipt filer on the PC. Each receipt is only sent once; sent ones show a "Sent" label.

**Space**
- **Videos:** heaviest first. Mark some, then **Delete** or **Shrink** (re-saves them smaller, up to 1080p HD, at nearly the same quality).
- **Recordings:** screen recordings, biggest first.
- **Live Photos:** **Shrink** keeps the still photo and drops its short video, roughly halving the size.
- Shrinking keeps the date, place, favourite and albums. iOS asks once per batch to delete the originals; if you tap Don't Allow, nothing in that batch changes. Slow-motion videos are left alone.

**Phone**
- **Files:** pick a folder in Files (Downloads, iCloud Drive, On My iPhone) to see the biggest files, files untouched for a year, and identical copies (the original of each is never listed). Nothing is marked until you mark it.
- **Contacts:** finds cards saved more than once (same name, number or email) and merges them into one.
- **Reminders:** clears completed reminders older than a month and one-off events that ended more than two years ago. Repeating events, birthdays and subscribed calendars are left alone.
- **Checklist:** the things only you can do in Settings (Messages attachments, offloading apps, Safari data, emptying Recently Deleted…), with ticks that are remembered.

**Settings**
- **Appearance:** match the iPhone, light (cream paper) or dark (midnight navy).
- **Look through:** the time range for the Similar, Blurry, Duplicates and Receipts scans. Start with 30 days.
- **Similar photos:** how far apart shots can be, how alike they must be, and whether to include screenshots.
- **Blurry photos → Keep photos with people.**
- **Receipt filer:** the `https://…ts.net` address you open on your iPhone to reach the filer. It's shown in the filer's window on your PC when it starts (or run `tailscale serve status` there). Tap **Test connection** to check it. Tailscale must be on on the iPhone when you file receipts.
- **Move to an album instead:** removing sends things to a "Photo Tidy – To Review" album and deletes nothing.
- **Clear saved scan data:** the app remembers what it measured so later scans are quick. Clearing never touches your photos.

Deleted photos wait in **Recently Deleted** for 30 days. To get the storage back the same day, open Photos → Albums → Recently Deleted → Delete All.

---

## If you do get access to a Mac

Open `PhotoTidy.xcodeproj` in Xcode 16 or later, pick your Team under **Signing & Capabilities**, plug in the iPhone and press **Run**.

## What's in the folder

| File | What it does |
|---|---|
| `.github/workflows/build.yml` | Tells GitHub how to build PhotoTidy.ipa |
| `Config/Info.plist` | Permission messages for Contacts, Reminders and Calendars |
| `PhotoTidy/SimilarityEngine.swift`, `AnalysisCache.swift`, `ImageMetrics.swift` | Look-alike groups, best-shot ranking, blur and people detection |
| `PhotoTidy/PhotoScanners.swift` | Receipt and exact-duplicate finders |
| `PhotoTidy/MediaShrinker.swift` | Shrinking Live Photos and videos |
| `PhotoTidy/FilerClient.swift` | Sending receipts to the receipt filer |
| `PhotoTidy/LibraryTools.swift` | Screenshot, video, recording and Live Photo lists; deleting and albums |
| `PhotoTidy/PhoneTools.swift` | Files, contacts, reminders/events and the checklist |
| `PhotoTidy/AppModel.swift` | Settings and everything the screens show |
| `PhotoTidy/SimilarTab.swift`, `ClutterTab.swift`, `SpaceTab.swift`, `PhoneTab.swift` | The four tabs |
| `PhotoTidy/GroupReviewView.swift`, `PhotoViewer.swift` | Reviewing a group and full-screen compare |
| `PhotoTidy/SharedViews.swift`, `Theme.swift`, `ContentView.swift`, `SettingsSheet.swift` | Shared pieces, look, welcome screen, settings |
| `PhotoTidy/Shaders.metal`, `Effects.swift` | The focus check (drawn on the GPU) |
| `PhotoTidy/Assets.xcassets` | App icon and the stone photos |
| `PhotoTidy/Fonts/` | Cormorant Garamond, the headline serif (SIL Open Font License, included) |
