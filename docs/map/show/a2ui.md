+++
title = "A2UI"
summary = "Native panels from Extensions: A2UI 1.0 surfaces in a tab, or in a box of the sidebar"
aka = ["extension", "extensions", "a2ui surfaces"]
kind = "code"
intent = "goal"
research = "done"
refs = ["macos/Sources/Features/Dense/A2UISessions.swift", "macos/Sources/Features/Dense/DenseCatalog.swift", "macos/Sources/Features/Dense/A2UIView.swift"]

[[feature]]
id = "render"
title = "Draw A2UI 1.0 with the official SwiftUI renderer (a2ui-project/a2ui 0.11.0)"
status = "done"

[[feature]]
id = "session"
title = "One socket session per Extension: hello with renderer capabilities, a snapshot per surface, subscribe and unsubscribe"
status = "done"
note = "A bad message shows on its surface and asks for it again; nothing is replayed after a restart"

[[feature]]
id = "sidebar"
title = "In a box of the sidebar: a ui Surface placed there scrolls inside the box"
status = "done"
needs = ["/tabs/sidebar-boxes#show"]

[[feature]]
id = "tab"
title = "A tab of kind ui: the Extension's surface fills it; a tab like any other"
status = "done"
note = "Ordered, glued, renamed, ⌘1…⌘9 and closed (deleted, without asking) as a web tab is"

[[feature]]
id = "disconnected"
title = "Disconnected: the surfaces stay, greyed, with their inputs off, and come back on reconnect"
status = "done"

[[feature]]
id = "catalog"
title = "dense's catalog: SurfaceLink, StatusBadge, KeyValue, Section; focusSurface, invokeCommand, copyText"
status = "done"
note = "invokeCommand runs a Ghostty action; commands from Extensions wait for the extension-resources design"

[[feature]]
id = "catalog-more"
title = "DiffStat, Code, KeyHint and denGet in dense's catalog"
status = "todo"

[[feature]]
id = "side-pane"
title = "Beside an agent's terminal: a ui tab glued to it, as a combo"
status = "done"
needs = ["/tabs/combo#side-by-side"]

[[needs]]
on = "/deps/dennet#a2ui"
why = "Where each surface goes, and which Extension fills it, are kept in dennet"
+++

From the PRD "A2UI surfaces in Dense". An Extension (dowt, for one) is a
program that listens on a Unix socket. A Surface of kind ui is a tab it
draws, or its part of a box of the sidebar with placement naming the box. dense
connects to the socket and speaks A2UI 1.0
there, one JSON message per line; dense's own messages (hello, subscribe,
unsubscribe) are under a "dense" key. No code from the Extension runs in
dense, and nothing in the catalog acts without a click.
