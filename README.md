# Omarchy Network Hub (`yashwanth.link`)

A comprehensive, unified Network, Tailscale, and Firewall management plugin for Omarchy.

## Features
- **Network**: Wi-Fi toggling, DNS management (with floating terminal for custom IPs), signal strength diagnostics, latency monitors, and data usage.
- **Tailnet**: Manage your Tailscale devices, click to copy IPv4/Hostnames natively, and effortlessly send files using the integrated drag-and-drop Taildrop UI.
- **Firewall**: UFW quick port management and status.
- **Nautilus Integration**: "Send via Taildrop" right-click context menu integration for GNOME Files.

## Installation

```bash
omarchy plugin add https://github.com/yashwanth/omarchy-network-hub.git
```

*(Note: Replace the URL above with your actual repository URL once published!)*

### Nautilus Integration (Optional)

To enable the "Send via Taildrop" option in your file manager (Nautilus):

```bash
mkdir -p ~/.local/share/nautilus-python/extensions
cp ~/.config/omarchy/plugins/yashwanth.link/nautilus-extension/taildrop.py ~/.local/share/nautilus-python/extensions/
nautilus -q
```

## Drag & Drop

Just drag any file(s) over the plugin icon on your top bar. The panel will automatically open and provide a huge target area to drop the files. If you only have one online device, the plugin intelligently skips the device selection menu and sends the file immediately.
