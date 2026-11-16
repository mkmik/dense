+++
title = "Web"
summary = "A web page in a tab: one page, or a small browser with navigation"
aka = ["browser", "webkit", "web view", "html"]
kind = "code"
intent = "goal"
research = "done"
refs = ["macos/Sources/Features/Dense/WebPage.swift", "macos/Sources/Features/Dense/SpaceTabs.swift"]

[[feature]]
id = "page"
title = "One page: a URL or the HTML itself; a clicked link opens in the default browser"
status = "done"
note = "Changing the Surface's html or url shows the new page"

[[feature]]
id = "browser"
title = "A browser: links open in the tab, with back, forward, reload and an address field"
status = "done"
note = "Where it browses stays in the window; the Surface keeps the page it started on"

[[feature]]
id = "combo"
title = "Glued beside a terminal, or another web tab, side by side"
status = "done"
note = "The line between them drags, and the width is kept with the bond, as t8y:/tabs/combo#resize"
needs = ["/tabs/combo#side-by-side"]

[[feature]]
id = "new"
title = "New Browser Tab… and New Web Page Tab… in the command palette"
status = "done"

[[feature]]
id = "keys"
title = "Ghostty's key bindings (⌘1…, ⌘[) while a page has the focus"
status = "todo"
note = "Only those in the menus work there: ⌘T, ⌘W. Click a tab, or into a terminal, for the rest; the command palette too"

[[needs]]
on = "/deps/dennet#web"
why = "The page, and whether it navigates, are kept on the Surface"
+++

A Surface of kind web shows a WebKit view. `spec.web` has the page, as
`url` (https, or file:// on this Mac) or as `html`, and `navigation`.
Without navigation the tab is one page: a program can show an artifact
there, glued beside its terminal, and change the html to update it.
With navigation it is a browser.

Like a terminal tab, its page stays loaded while the tab is out of view.
