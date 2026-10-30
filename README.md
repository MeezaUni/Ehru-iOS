# Erhu-iOS

Erhu is a local music player for iOS, based on the Android project credited in [the third-party notice](ThirdParty/ANDROID-NOTICE.md).
Written in Swift and SwiftUI, and built in the cloud by GitHub Actions, so no up-to-date Mac is needed.

## What works so far

- Library of the audio files in the app's folder (MP3, M4A/AAC/ALAC, FLAC, WAV, AIFF), with title,
  artist, album and artwork read from the tags
- Importing songs with the **+** button, or dropping them into **Files → On My iPhone → Erhu**
- Search, swipe to delete, pull to refresh, shuffle all
- Mini player and a Now Playing screen with seeking, shuffle and repeat (off / all / one)
- Background playback, lock screen and Control Center controls, pausing on calls and when
  headphones are unplugged

## Getting a build onto an iPhone (free Apple ID)

1. Every push runs the **iOS** workflow under the repo's **Actions** tab. Open the latest green run
   and download **Erhu-ipa** at the bottom. GitHub wraps it in a zip; unzip it in the Files app to
   get `Erhu.ipa`.
2. Install it with [SideStore](https://sidestore.io) or [AltStore](https://altstore.io). They sign
   the app with your own Apple ID while installing it. The first SideStore setup needs a computer
   once; after that it works from the phone.
3. Free Apple ID limits: the app needs refreshing in SideStore/AltStore every 7 days, and at most
   3 sideloaded apps can be active on a phone at once.

## Working on it on a Mac

The Xcode project is generated from `project.yml`, which keeps merge conflicts out of
`.xcodeproj` files.

```sh
brew install xcodegen
xcodegen generate
open Erhu.xcodeproj
```

To run on your own phone from Xcode, pick your Apple ID's Personal Team under
Signing & Capabilities. Don't commit `Erhu.xcodeproj`; it's ignored and regenerated each time.

## Layout

| Folder | What's in it |
|---|---|
| `Erhu/App` | App entry point and root view |
| `Erhu/Core/Library` | Finding, importing and reading tags from music files |
| `Erhu/Core/Playback` | Play queue (shuffle, repeat) and the AVPlayer-based player |
| `Erhu/UI` | SwiftUI screens |
| `ErhuTests` | Unit tests |
| `Support/Info.plist` | Background audio, Files app access |
