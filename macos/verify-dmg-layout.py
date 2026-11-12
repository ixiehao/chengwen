"""Validate Finder metadata after mounting the final read-only installer."""
import os
import sys

from ds_store import DSStore
from mac_alias import Alias


mount, application = sys.argv[1:]
with DSStore.open(os.path.join(mount, ".DS_Store"), "r") as store:
    assert store["."]["icvl"] == (b"type", b"icnv"), "Default view is not icon view"
    window = store["."]["bwsp"]
    assert window["WindowBounds"] == "{{160, 120}, {960, 600}}", window
    assert not window["ShowToolbar"] and not window["ShowSidebar"], window
    view = store["."]["icvp"]
    assert view["backgroundType"] == 2, "Background is not an image"
    assert view["iconSize"] == 128 and view["arrangeBy"] == "none", view
    assert store[application]["Iloc"] == (260, 298), "App position changed"
    assert store["Applications"]["Iloc"] == (700, 298), "Applications position changed"
    assert not list(store.find(".", b"pBBk")), "Obsolete background bookmark causes a white Finder background"
    saved_alias = Alias.from_bytes(view["backgroundImageAlias"])
    actual_alias = Alias.for_file(os.path.join(mount, ".background.png"))
    assert saved_alias.target.cnid == actual_alias.target.cnid, "Background alias points to the wrong file"
    assert saved_alias.target.creation_date == actual_alias.target.creation_date, "Background alias is stale"

assert os.path.isfile(os.path.join(mount, ".background.png"))
assert os.readlink(os.path.join(mount, "Applications")) == "/Applications"
print("Finder layout verified: background, icon view, window, icon positions, Applications link")
