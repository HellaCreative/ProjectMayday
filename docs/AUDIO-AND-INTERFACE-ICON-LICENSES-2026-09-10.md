# Audio and interface icon source record

The active startup audio is Richard Smith's original motorcycle recording, supplied September 10, 2026 as `/Users/richardsmith/SandBox01/MAYDAYiOS/Assets/MyKTM.m4a`. Richard explicitly identified it as his own recording and authorized replacement of the Pixabay sample. Bundled as `Dirt/Resources/MyKTM.m4a`, AAC stereo at 48 kHz, duration 3.305 seconds, source SHA-256 `a8219b89fee587186ee492af96a95e09a122eb22d9fb00fa20dde9ffc1fd4143`. Playback uses AVAudioPlayer directly; no conversion, trimming or animation changes.

The former bundled `firtbike.mp3` is removed and the active audio notice now credits the owner recording. The original supplied MP3 outside the app remains untouched. The exact Pixabay download clearance is no longer an open requirement for this replacement audio; already-uploaded older builds still contain their previous resource.

Native interface code uses Apple SF Symbols through Image(systemName:) and UIImage(systemName:), including map controls, routing tabs, groups, profile, subscription and onboarding. SF Pro is the typeface, not the icon library. Governing Apple Xcode and SDK terms: https://www.apple.com/legal/sla/docs/xcode.pdf . Official implementation documentation: https://developer.apple.com/documentation/uikit/configuring-and-displaying-symbol-images-in-your-ui . Do not assume Apple symbol assets may be ported to Android.

Base-map sprite artwork is separately sourced from SVWD03, not Apple's interface symbols. See SVWD03-STYLE-SPRITE-PROVENANCE-2026-09-05.md. Identifying licences does not establish that all required notices/source-distribution obligations are already satisfied. No app code, prices or App Store rights declarations changed in this check.

Verification: unsigned DIRT Production Release build passed (`/tmp/dirt-ktm-audio-build.log`). Bundled MyKTM.m4a matches the source byte-for-byte; former MP3 and Pixabay credit are absent. Physical playback remains for the next designated-device test. No archive or upload performed.
