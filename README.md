# Omarchy Network Hub (`yashwanth.link`)

A comprehensive, unified Network, Tailscale, and Firewall management plugin for Omarchy.

## Features
- **Network**: Wi-Fi toggling, DNS management, signal strength diagnostics, latency monitors, and data usage.
- **Tailnet**: Manage your Tailscale devices, click to copy IPv4/Hostnames natively, and effortlessly send files using the integrated drag-and-drop Taildrop UI.
- **Firewall**: UFW quick port management and status.
- **Nautilus Integration**: "Send via Taildrop" context menu integration for GNOME Files.

## Installation

```bash
omarchy plugin add https://github.com/yashwk/OmaNetHub.git
```

*(Note: Replace the URL above with your actual repository URL once published!)*

### Nautilus Integration

The "Send via Taildrop" option is **automatically integrated** into your GNOME Files (Nautilus) right-click context menu when the plugin first loads! There is no manual setup required.

## Drag & Drop

Just drag any file(s) over the plugin icon on your top bar. The panel will automatically open and provide a target area to drop the files. If you only have one online device, the plugin intelligently skips the device selection menu and sends the file immediately.
