<p align="center">
  <img src=".github/icon.png" width="128" alt="Nubbin icon">
</p>

<h1 align="center">Nubbin</h1>

<p align="center">Your coding agents, in the notch.</p>

<p align="center">
  <img src=".github/expanded.png" width="700" alt="The open island: an omp question with its options, a Claude Code approval with Approve and Deny, a finished Codex task, and a running omp task">
</p>

Nubbin is a macOS menu bar app. It chimes when an agent needs you, finishes, or fails, and shows what it wants in the notch. Click a row to jump to its terminal pane.

<p align="center">
  <img src=".github/folded.png" width="500" alt="The folded island: one dot per session and a count of sessions that need you">
</p>

## Agents

Every agent shows when it is working and when it is done.

| Agent | Connects through | Also shows | Answer in the notch |
|---|---|---|---|
| [omp](https://omp.sh) | extension | current step, questions and options, approvals, failures | no |
| [Claude Code](https://docs.anthropic.com/en/docs/claude-code) | hooks | questions and options, approvals, failures | approvals |
| [Codex](https://github.com/openai/codex) | hooks | the command it wants to run | no |
| [pi](https://github.com/earendil-works/pi) | extension | failures | no |

Where the notch can't answer, click the row to jump to the pane and answer there.

In [zellij](https://zellij.dev), each row names its session and tab, and a click switches to that tab and pane. Any tab that rings the terminal bell gets a row too.

## Install

You need macOS 14 or later and Xcode 26 or later.

```sh
make install
open ~/Applications/Nubbin.app
```

Then connect your agents, either from **Settings › Agents** or with:

```sh
make hooks
```

Nubbin backs up each settings file before it changes it, and leaves other hooks alone.

- **Codex** runs new hooks only after you approve them. Run `/hooks` in Codex.
- **omp**: run `/reload-plugins` in sessions that are already open.
- **pi**: restart open sessions.

Run `make` to list every target.

## Settings

Open Settings from the menu bar icon (⌘,) or the gear in the island. If you hide the menu bar icon (Settings › General), open Nubbin again from Spotlight or Finder to get Settings back. Each moment (needs you, finished, failed) has its own sound, volume, color, and ring. Trim any sound, or drop in your own. Press ⌘R to play a moment exactly as it will happen.

- **Reminders**: ring again after a delay, once, three times, or until it's handled.
- **Quiet**: silence chimes during Focus, calls (microphone or camera in use), mirrored displays, or quiet hours. The notch still rings. Turned-on Focus is read from `~/Library/DoNotDisturb`; scheduled Focus isn't visible to apps.
- **Away**: when the screen is locked or you've been idle, post to Notification Center, push to your phone through [ntfy](https://ntfy.sh), or both.
- **Agents**: per agent (and for zellij tab bells), chime, show only, or hide.
- **Island**: open on hover or only on click, dots for every session or only ones that need you, clear finished rows when you open them, and which display it lives on.
- **Shortcuts**: global hotkeys to open the island and to jump to the session that needs you.
- **Export/import**: move your settings to another Mac (sounds you added aren't included).

The menu bar icon shows how many sessions are waiting. Its menu lists every session (click to jump, hold ⌥ to dismiss), and can mute chimes for 15 minutes, an hour, three hours, or until tomorrow morning.

## How it works

Each agent runs `Nubbin hook`, or the bundled extension, on every event. It sends the event as JSON to a Unix socket at `~/Library/Application Support/Nubbin/events.sock`, which only you can read. Nothing leaves your Mac unless you set an ntfy topic for away notifications.

For a Claude Code approval, the hook waits for your answer. Claude keeps its own prompt open meanwhile, and the first answer wins.

Set `NUBBIN_DEBUG=1` to log events to stderr.

## Uninstall

```sh
make unhooks
rm -rf ~/Applications/Nubbin.app "$HOME/Library/Application Support/Nubbin"
defaults delete dev.jacobcoffee.nubbin
```
