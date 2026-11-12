import os

application = defines.get("app", "澄闻.app")
application_name = os.path.basename(application)

# Apple hdiutil documents ULMO support from macOS 10.15, below our 12.0 floor.
format = "ULMO"
filesystem = "HFS+"
files = [application]
symlinks = {"Applications": "/Applications"}

background = defines.get("background", "dmg-background.png")
window_rect = ((160, 120), (960, 600))
show_toolbar = False
show_status_bar = False
show_sidebar = False
show_pathbar = False
show_tab_view = False
default_view = "icon-view"
icon_view_settings = {
    "arrange_by": None,
    "grid_offset": (0, 0),
    "grid_spacing": 100,
    "icon_size": 128,
    "label_pos": "bottom",
    "text_size": 13,
}
icon_locations = {
    application_name: (260, 298),
    "Applications": (700, 298),
}
