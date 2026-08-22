import os
import shutil

from gi import require_version

require_version("Nautilus", "4.1")

from gi.repository import GObject, Gio, Nautilus

class SendViaTaildropAction(GObject.GObject, Nautilus.MenuProvider):
    def _launch_taildrop(self, paths):
        config_home = os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config"))
        script_path = os.path.join(config_home, "omarchy/plugins/yashwanth.link/bin/taildrop-menu-send")
        if not os.path.exists(script_path):
            return
        command = [script_path] + paths
        Gio.Subprocess.new(command, Gio.SubprocessFlags.NONE)

    def _selected_paths(self, files):
        paths = []
        for file in files:
            location = file.get_location()
            if not location:
                continue
            path = location.get_path()
            if path and path not in paths:
                paths.append(path)
        return paths

    def _make_item(self, paths):
        label = "Send via Taildrop" if len(paths) == 1 else "Send selected via Taildrop"
        item = Nautilus.MenuItem(
            name="TaildropNautilus::send_via_taildrop",
            label=label,
            icon="tailscale",
        )
        item.connect("activate", self._on_activate, paths)
        return item

    def _on_activate(self, _menu, paths):
        self._launch_taildrop(paths)

    def get_file_items(self, *args):
        files = args[0] if len(args) == 1 else args[1]
        paths = self._selected_paths(files)

        if not paths:
            return []

        return [self._make_item(paths)]
