from pathlib import Path

app = Path(defines["app"])
files = [str(app)]
symlinks = {"Applications": "/Applications"}
format = "UDZO"
background = defines["background"]
window_rect = ((180, 180), (704, 352))
icon_size = 78
text_size = 14
icon_locations = {app.name: (189, 132), "Applications": (515, 132)}
