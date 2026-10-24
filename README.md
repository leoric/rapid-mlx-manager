# rapid-manager

**rapid-manager** is a lightweight macOS menu bar GUI for managing local AI models running via [`rapid-mlx`](https://rapidmlx.com/). It provides quick visibility and instant control over running model servers directly from your menu bar.
---

## Features

- **Menu Bar Control**: View current server status (Running/Stopped), loaded model and local endpoint.
- **Quick Model Switching**: Instantly switch the active model served by `rapid-mlx serve`.
- **Downloaded Models**: View cached Hugging Face models, inspect underlying CLI output, select models to use, or remove them.
- **Model Catalog**: Browse available models/aliases, search by term or filter by modality (`text`, `audio`, `video-gen`, `image-gen`), and pull models directly from Hugging Face.
- **Active Servers & Activity**: Monitor running `rapid-mlx` server processes (`rapid-mlx ps`) and view system logs.
- **Flexible Configuration**: Auto-detect or manually configure the path to the `rapid-mlx` binary and target models directory (`HF_HUB_CACHE`).

---

## Requirements

- **macOS** (Apple Silicon recommended for MLX acceleration)
- `rapid-mlx` installed and accessible in your system path

---

## Overview & UI

### 1. Menu Bar Popover
Access the primary controls directly from the macOS tray:
- **Status Indicator**: Shows server state and base endpoint.
- **Quick Switch**: Radio list of cached models to start or switch on the fly.
- **Shortcuts**: Buttons to open the Manager window, Logs, Settings, or Quit the app.

### 2. Model Manager (`Downloaded` & `Catalog`)
- **Downloaded Tab**: Equivalent to `rapid-mlx models --cached` / `rapid-mlx ls`. Displays model sizes, active selection, and option to delete caches (`rapid-mlx rm`). Includes collapsible raw CLI output.
- **Catalog Tab**: Equivalent to `rapid-mlx models`. Allows searching aliases, filtering by modality, pulling predefined recipes, or pulling custom Hugging Face repositories.

### 3. Server Status (`Servers` & `Activity`)
- View active instances running via `rapid-mlx ps`.
- Check live logs and process outputs.

### 4. Settings
- **Binary Path**: Configure path to `rapid-mlx` (e.g., `/Users/username/.venv/bin/rapid-mlx`) with auto-detection support.
- **Models Folder**: Custom cache directory passed as `HF_HUB_CACHE`.
- **Endpoint**: Configure local server endpoint (e.g., `http://127.0.0.1:8000`).