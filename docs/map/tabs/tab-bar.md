+++
title = "Tab bar"
summary = "The selected Space's tabs in the titlebar row, one handle per Surface"
kind = "code"
intent = "goal"
research = "done"
refs = ["macos/Sources/Features/Dense/SpaceWindowView.swift"]

[[feature]]
id = "show"
title = "One handle per Surface: icon, title or number, the tab in front on a pill"
status = "done"

[[feature]]
id = "reorder"
title = "Drag a handle to another place in the row; writes spec.order"
status = "done"

[[feature]]
id = "menu"
title = "Rename, and close or detach from the den, from a handle's menu"
status = "done"

[[needs]]
on = "/deps/dennet#api"
why = "Tabs are Surfaces in dennet; their order and title are written there"
+++

Every tab of the Space has a handle here. Nothing is hidden inside a tab.
