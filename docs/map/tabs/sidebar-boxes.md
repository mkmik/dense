+++
title = "Sidebar boxes"
summary = "Named slots of a set size under the Space tree, showing the selected Space's Surfaces placed there"
aka = ["placement", "box", "boxes", "sidebar section", "detail box"]
kind = "code"
intent = "goal"
research = "done"
refs = ["macos/Sources/Features/Dense/SidebarBoxes.swift", "macos/Sources/Features/Dense/SpaceSidebar.swift", "src/config/Config.zig"]

[[feature]]
id = "show"
title = "A box for every name a Surface's placement uses, under the Space tree, showing the selected Space's Surfaces in it"
status = "done"
needs = ["/deps/dennet#placement"]
note = "There whichever Space is selected; an empty one says so at full height"

[[feature]]
id = "size"
title = "Its height from the config, never from what is in it: sidebar-box = name:lines, listed boxes first"
status = "done"
note = "Unlisted names get 8 lines, after the listed boxes, by name"

[[feature]]
id = "resize"
title = "Drag a box's top edge to change its height, for every window; double-click it for the config's"
status = "done"

[[feature]]
id = "fold"
title = "A box's name folds it, per window, whichever Space is selected"
status = "done"

[[feature]]
id = "short"
title = "In a short window the Space tree keeps 6 rows; the boxes get shorter"
status = "done"

[[feature]]
id = "move"
title = "Move to Box on a tab's menu, with New Box…; Move to Tabs, Rename and Close on a box's"
status = "done"
note = "Moving unglues it; the tab in front gives way to the next"

[[feature]]
id = "fallback"
title = "A Space with nothing for a box shows the nearest Space above's, as working directories are inherited"
status = "todo"
+++

A Surface is a tab, or with spec.placement set to a box's name it goes in
that box: one model for both, so a Surface in a box is renamed, closed,
cleaned up with its Extension and seen by other tools as a tab is.

From the design note "Sidebar Boxes": a box's size comes from the layout,
not from what is in it, and a box is there when any Space uses it, not
only the selected one. So switching Spaces changes what is in a box, never
where it is or how big, and the Space tree above it never moves. A first
try, placement sidebar, stacked the selected Space's Surfaces under the tree
as tall as they drew, and moved the tree on every switch.

The config only orders boxes and sets their heights; any name gets a box,
so a name from an Extension or another machine never hides a Surface.
Several Surfaces of a Space in one box share it evenly, each under its
title. A terminal there attaches its den at the box's size, apart from the
tabs'.
