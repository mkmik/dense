+++
title = "Sidebar sections"
summary = "Any Surface placed in its Space's sidebar instead of the tab row, as a section that folds"
aka = ["placement", "sidebar section"]
kind = "code"
intent = "goal"
research = "done"
refs = ["macos/Sources/Features/Dense/SidebarSections.swift", "macos/Sources/Features/Dense/SpaceTabs.swift"]

[[feature]]
id = "show"
title = "The selected Space's Surfaces with placement sidebar, under the Space tree, each under its title, which folds it"
status = "done"
needs = ["/deps/dennet#placement"]
note = "An Extension's (kind ui) is as tall as it draws; a page or a terminal is 200 points tall"

[[feature]]
id = "move"
title = "Move to Sidebar on a tab's menu; Move to Tabs, Rename and Close on a section's"
status = "done"
note = "Moving unglues it; the tab in front gives way to the next"

[[feature]]
id = "resize"
title = "Drag a section's bottom edge to make a page or terminal taller"
status = "todo"
+++

A Surface is a tab, or with spec.placement sidebar a section of its Space's
part of the sidebar: one model for both, so a section is renamed, closed,
cleaned up with its Extension and seen by other tools as a tab is. A
section's terminal or page is its own, apart from the tabs': a terminal
there attaches its den at the sidebar's width.
