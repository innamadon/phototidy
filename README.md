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

The floating bar at the bottom has four places and a Settings button.

**Similar** — look-alike photos
1. Tap **Find look-alikes**. Groups ("moments") appear while it scans, newest first. Keep the app open during a scan.
2. Tap **Review one by one**. In each group the suggested keeper is on top, marked **Best**.
   - Tap a photo to switch it between keep and let go. Photos you're letting go fade to grey.
   - Tap the corner arrows to compare full screen: pinch to zoom, **hold "Hold for Best"** to flip to the best shot, and turn on **Focus check** to light up the parts that are truly sharp.
   - Tap **Looks good — next** to move on. The red brush line shows how far through you are.
3. Back on the Similar screen, tap **Delete … extras**. iOS asks once to confirm.

**Blurry** — photos where nothing is in focus
- Tap **Find blurry photos**. Nothing is pre-marked; tap the ones to remove, or **Mark all**.
- The **Fewer / More** slider decides how soft a photo has to be to show up. Favorites are never suggested.
- Press and hold a photo to see it larger.

**Shots** — screenshots, oldest first, with an age filter (all, 1 month+, 6 months+, 1 year+).

**Videos** — every video, heaviest first. Tap a row to mark it; tap the picture to play it.

**Settings**
- **Appearance:** match the iPhone, light (cream paper) or dark (midnight navy).
- **Look through:** last 30 days, 3 months, a year, or everything. Used by the Similar and Blurry scans. Start with 30 days.
- **Shots taken within / How alike / Include screenshots:** tune what counts as a look-alike. If groups mix different scenes, slide toward Strict; if obvious look-alikes are missed, slide toward Loose.
- **Move to an album instead:** when on, removing sends items to a "Photo Tidy – To Review" album and deletes nothing. (This needs full photo access.)
- **Clear saved scan data:** the app remembers what it measured so later scans only look at new or edited photos. Clearing it never touches your photos.

Deleted items wait in **Recently Deleted** for 30 days. To get the storage back the same day, open Photos → Albums → Recently Deleted → Delete All.

How the best shot is chosen: sharpness, faces (the worst face counts extra, so one blink costs a lot), lighting, resolution, and on iOS 18 or later Apple's own "how good does this look" score. Favorites always win; edited photos get a small boost.

The first scan is the slow one, especially when photos are stored in iCloud and have to download.

---

## If you do get access to a Mac

Open `PhotoTidy.xcodeproj` in Xcode 16 or later, pick your Team under **Signing & Capabilities**, plug in the iPhone and press **Run**.

## What's in the folder

| File | What it does |
|---|---|
| `.github/workflows/build.yml` | Tells GitHub how to build PhotoTidy.ipa |
| `PhotoTidy/SimilarityEngine.swift` | Finds look-alike groups, ranks photos, finds blurry ones |
| `PhotoTidy/AnalysisCache.swift` | Remembers measurements between scans |
| `PhotoTidy/ImageMetrics.swift` | Sharpness, edge strength and lighting measures |
| `PhotoTidy/LibraryTools.swift` | Lists screenshots and videos; deletes or moves to the album |
| `PhotoTidy/AppModel.swift` | Settings, scan state, picks, removing |
| `PhotoTidy/ContentView.swift` | Tabs, welcome screen, the "cleared" summary |
| `PhotoTidy/SimilarTab.swift`, `GroupReviewView.swift`, `PhotoViewer.swift` | Similar tab, reviewing a group, full-screen compare |
| `PhotoTidy/LibraryTabs.swift` | Blurry, Screenshots and Videos tabs |
| `PhotoTidy/SettingsSheet.swift` | Settings |
| `PhotoTidy/Theme.swift` | Colours, type, buttons, cards, brush line, floating tab bar |
| `PhotoTidy/Shaders.metal`, `Effects.swift` | Stone texture and focus check (drawn on the GPU) |
| `PhotoTidy/Fonts/` | Cormorant Garamond, the headline serif (SIL Open Font License, included) |
