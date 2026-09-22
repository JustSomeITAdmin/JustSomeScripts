# Assets

Drop your organization's logo here as `AppIcon.png` (square, transparent PNG, 256px or larger). `Config\config.psd1` points the
toolkit at `..\Assets\AppIcon.png`, so it appears on every dialog the package shows - the restart prompt and the countdown.
Without it the toolkit's default icon is used, which is fine for testing. Optionally add `Banner.Classic.png` for classic-style
dialogs.

This folder ships no icon on purpose - use your own. The logo shown for the app in Intune/Company Portal is separate and is
set on the Win32 app in the portal.
