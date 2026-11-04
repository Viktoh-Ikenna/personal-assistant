# BugMe 🐞

A personal, offline iPhone assistant that nags you until things get done.

- **Bugs tab**: tasks that send escalating repeat notifications, with **Done ✅** and **Snooze** buttons in the notification.
  Bugs can repeat daily, weekly or monthly; marking one done schedules the next.
- **Floating mic**: on-device voice commands ("pay rent on the 1st of every month", "gym every monday at 6pm",
  "I finished calling mom", "what's on my list?").
- **Check-in tab**: morning goals (each line becomes a task) and an evening reflection with mood and a streak.
- **Siri**: "Hey Siri, bug me with BugMe".

## Install on your iPhone
1. `xcodegen generate` (only needed after adding or removing files), then `open BugMe.xcodeproj`.
2. Target **BugMe → Signing & Capabilities → Team**: pick your Apple ID.
   If the bundle ID is taken, change `com.bugme.personal.app` to something unique.
3. Plug in your iPhone, enable **Developer Mode** (Settings → Privacy & Security), select the phone, and press ▶︎.
4. On the phone, trust the developer: Settings → General → VPN & Device Management.

Free Apple ID builds expire after 7 days. Press ▶︎ again to renew.

## Notes
- iOS allows 64 scheduled notifications. BugMe plans up to 12 nags per task, then re-plans every time you open the app.
- Everything is stored on the device with SwiftData. Nothing is sent over the network.

## Demo data (simulator)
`xcrun simctl launch booted com.bugme.personal.app -seedDemo` replaces all bugs with sample ones (Debug builds only).
