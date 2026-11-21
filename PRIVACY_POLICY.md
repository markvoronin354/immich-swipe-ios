# Privacy Policy for Immich Swipe (iOS)

**Last Updated:** November 21, 2026

## 1. Overview

**Immich Swipe** ("the Application") is an open-source iPhone and iPad app (which also runs on Apple silicon Macs as the iPad app) that helps you
sort, manage and clean up the photos and videos on your own self-hosted [Immich](https://immich.app/) server.

**Immich Swipe does not collect, store, transmit, sell or share any personal data, usage analytics or telemetry
with the developer or any third party.** The only server it talks to is the Immich server you enter.

---

## 2. Information Handled by the Application

### A. Server Connection Credentials
* **What is stored:** Your Immich server URL, your API key and any custom request headers you add for your server.
* **How it is used:** Only to authenticate requests between your device and your Immich server.
* **Storage location:** The API key and custom headers are stored in the iOS Keychain, available only on this device
  after it has been unlocked. They are never sent anywhere except the Immich server you entered.
* **Unencrypted connections:** You can enter an `http://` server address. Over plain HTTP your API key and media
  travel unencrypted. The app asks you to confirm before connecting this way to a server that isn't on a private
  network.

### B. Photos, Videos and Media Metadata
* **What is processed:** Thumbnails, photos, videos, metadata (such as EXIF and dates), album information and
  duplicate groups from your Immich server.
* **How it is used:** To show your media in the app and carry out the actions you choose (delete, keep, favorite,
  archive, lock, add to album, edit descriptions). These actions are sent only to your Immich server.
* **Sharing:** Media leaves the app only when you explicitly use the Share button, which hands the item to the app
  you pick in the iOS share sheet.

### C. Local Storage & Cache
* **Decisions:** Your swipe decisions are stored in a local database on your device.
* **Media cache:** Images are cached on your device so the app runs smoothly.
* **Logs:** A small diagnostic log is kept on your device. It is never uploaded; you can view it, share it yourself
  or clear it in the app. The same messages are also written to the iOS system log on your device.
* **Control:** You can export, import or reset your decisions and clear caches from **Settings**.

---

## 3. Permissions

* **Photos (add only):** Asked for only when you save a photo or video from your Immich server to your Photos
  library. The app can add items but cannot read your library.
* **Local Network:** Used to reach your Immich server when it is on your home network.
* **Notifications:** Optional. Used only for the sorting reminders you turn on in Settings. They are scheduled on
  your device; no push service is used.

---

## 4. Third-Party Services & Analytics

* **No analytics or telemetry.**
* **No crash-reporting services.**
* **No advertising.**
* **No data transfers to anyone other than your own Immich server.**

---

## 5. Data Retention & Deletion

* All settings, account details and decisions stay on your device.
* Signing out of an account removes that account's credentials from the device.
* Deleting the app removes its local data, caches and database from your device.

---

## 6. Children's Privacy

Immich Swipe does not knowingly collect personal information from anyone, including children, because it collects
no personal data at all.

---

## 7. Changes & Contact

Changes to this policy will be published in this repository. For questions, open an issue at
[github.com/markvoronin354/immich-swipe-ios](https://github.com/markvoronin354/immich-swipe-ios/issues).
