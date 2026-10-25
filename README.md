# RapidManager

A lightweight macOS menu bar app for managing a local [Rapid-MLX](https://rapidmlx.com) installation. Start, stop and restart the server, switch models, manage downloaded models, and watch the logs, all without a terminal.

RapidManager does not bundle Rapid-MLX. It drives your existing `rapid-mlx` binary.

---

## Features

- **Server control:** Start, Stop and Restart `rapid-mlx serve`. The status shows Running, Starting, Stopping, Stopped or Failed. If another process is already using the port, the app shows "started elsewhere" and does not try to control it.
- **Model switching:** Pick a downloaded model from the menu. If the server is running it restarts with the new model; if it is stopped, the model is only selected.
- **Thinking switch:** The "Thinking" checkbox controls `--no-thinking`. Checked: no flag. Unchecked: the server starts with `--no-thinking`. Toggling it restarts a running server.
- **Model manager:**
  - *Downloaded:* models from `rapid-mlx models --cached`; use or remove them.
  - *Catalog:* models from `rapid-mlx models`; search by term, filter by modality (`text`, `audio`, `video-gen`, `image-gen`), and pull an alias or any Hugging Face repo.
  - *Servers:* the output of `rapid-mlx ps`.
  - *Activity:* live progress and logs of pulls and removals, with Cancel.
- **Logs window:** Live output of the server process.
- **Configurable:** Path to the `rapid-mlx` binary, models folder, and host/port.

---

## Requirements

- Apple Silicon Mac (required by MLX) running macOS 13 or later
- [Rapid-MLX](https://github.com/raullenchai/Rapid-MLX) installed (the app needs the path to the binary, not a `PATH` entry)
- Swift toolchain to build (Xcode or the Command Line Tools); no Xcode project is needed

---

## Build and run

```sh
./build.sh
open build/RapidManager.app
```

The app lives in the menu bar only (no Dock icon). Quitting the app also stops a server it started.

---

## Usage

### Menu bar popover (left click)

- Status, endpoint and the active model; the last server log line.
- Start / Stop / Restart and the **Thinking** checkbox.
- List of downloaded models. Click one to make it active.
- **Manage…**, **Logs…**, **Settings…** and **Quit**.

**Right-click** the icon to open or close the model manager. **Esc** closes the Manager, Logs and Settings windows.

### Model manager

Sizes are shown only when `rapid-mlx` reports them; otherwise you will see "—". Catalog sizes are approximate download footprints. Each list has a collapsible *Raw CLI output* box for troubleshooting.

Removing a model that the running server is using is blocked; stop the server or switch models first.

### Settings

- **Rapid-MLX binary:** Path to `rapid-mlx` (for example `~/.venv/bin/rapid-mlx`). *Auto-detect* checks common install locations and your login shell's `PATH`. A green check means the file is executable.
- **Models folder:** Optional. By default the app looks in `~/.cache/huggingface/hub`, `~/.cache/huggingface`, `~/.cache/rapid-mlx` and `~/.rapid-mlx`. If set, the folder is used instead and also passed to Rapid-MLX as `HF_HUB_CACHE`.
- **Endpoint:** Host and port, passed as `--host` and `--port`. Default is `127.0.0.1:8000`. Applying a change restarts a running server.

---

## Notes

- Server status is detected with a plain TCP check on the configured port.
- The app is ad-hoc signed by `build.sh`; it is meant for local use.
