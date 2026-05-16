# wire

<p align="center">
  <img src="Assets/wire.iconset/icon_512x512.png" width="128" alt="wire icon">
</p>

`wire` is a small macOS menu bar voice transcriber. It records from your microphone, sends audio to the same ChatGPT/Codex transcription endpoint used by Codex dictation, then copies/pastes the transcript.

## Requirements

- macOS 14+
- Xcode command line tools / SwiftPM
- You must be logged into Codex/ChatGPT so `~/.codex/auth.json` exists.
- Microphone permission for the app.
- Accessibility permission if you want `wire` to paste text into the active app.

## Run locally

```bash
./run.sh
```

`run.sh` builds if needed, packages `dist/wire.app`, and opens it.

## Install to `/Applications`

```bash
./install.sh
```

`install.sh` builds if needed, packages `dist/wire.app`, copies it to:

```text
/Applications/wire.app
```

and opens it. If `/Applications` requires admin rights, the script will ask via `sudo`.

## Usage

- Menu bar icon: click the microphone to open settings and the latest transcript.
- Two shortcuts are available:
  - **Hold shortcut**: hold to record, release to stop and transcribe. Default: `⌃⌥M`.
  - **Toggle shortcut**: press once to start, again to stop and transcribe. Default: `⌘⇧M`.
- Toggle recordings do not have a fixed local time cap. While recording, the menu bar item shows `REC` with the elapsed duration so you can spot an accidentally active recording.
- Click either shortcut button to reset it. While recording a new shortcut, the button shows `Listening…`, then updates live as you press modifiers/keys (for example `⌘⇧M`). It saves when all keys are released; press `Esc` to cancel.
- **Headset controls** can be disabled with one switch. When disabled, wired headset controls, AirPods controls, and headset-only Return-after-paste are all inactive.
- Wired headset button modes are **Long hold to dictate** and **Long press to toggle**.
- **AirPods controls (experimental)** maps the AirPods left-tap / next-track control to start or continue recording from the AirPods microphone when available. Since AirPods media taps are not reliable while that microphone is active, `wire` auto-stops after a short silence. Right tap / play-pause submits with Return when not recording.
- **Wired sends Return** sends Return only after transcripts started from the wired headset button.
- The latest transcript appears in the popover, with a copy button beside it.
- Transcripts are always copied to the clipboard. If Accessibility permission is granted, `wire` also pastes the transcript into the active app.
- On launch, `wire` attempts to register itself as a login item so it starts automatically when you log in.

## Troubleshooting

If transcription hangs or fails:

1. Make sure Codex auth exists:

   ```bash
   test -f ~/.codex/auth.json && echo ok
   ```

2. Relaunch the app:

   ```bash
   killall wire 2>/dev/null
   ./run.sh
   ```

3. If paste does not work, grant Accessibility permission to `wire` in System Settings.
