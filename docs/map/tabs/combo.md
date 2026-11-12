+++
title = "Combo tabs"
summary = "A tab glued beside another: both shown side by side, their handles fused into one"
aka = ["split", "sidebar", "attached surface", "glue", "unglue", "zoom"]
kind = "code"
intent = "goal"
research = "outline"
refs = ["macos/Sources/Features/Dense/SpaceTabs.swift", "macos/Sources/Features/Splits/SplitTree.swift"]

[[feature]]
id = "side-by-side"
title = "With either tab of a combo in front, both show, the glued one on the right"
status = "done"
milestone = "m1"
needs = ["/deps/dennet#glue"]

[[feature]]
id = "focus"
title = "Clicking into a pane, or moving the focus there, puts its tab in front"
status = "done"
milestone = "m1"
needs = ["#side-by-side"]

[[feature]]
id = "fused-handle"
title = "One fused handle: its left half picks the main tab, its right half the glued one"
status = "done"
milestone = "m1"
needs = ["#side-by-side", "/tabs/tab-bar#show"]

[[feature]]
id = "glue"
title = "Glue: ⌘-drag a handle onto another tab; it goes on that tab's right"
status = "done"
milestone = "m1"
note = "A plain drag still reorders. Neither tab may be in a combo already"
needs = ["#fused-handle", "/tabs/tab-bar#reorder"]

[[feature]]
id = "unglue"
title = "Unglue: ⌘-drag a half away from its combo; each becomes a full-width tab"
status = "done"
milestone = "m1"
note = "Takes the place of Ghostty's split zoom"
needs = ["#fused-handle"]

[[feature]]
id = "stops"
title = "Go to Tab (⌘1…), next and previous tab, and Go Back (⌘[) stop once per combo"
status = "done"
milestone = "m1"
note = "Going to a combo brings back the half that was last in front"
needs = ["#side-by-side"]

[[feature]]
id = "commands"
title = "Glue to the tab on the left, and unglue, from the palette and a tab's menu"
status = "done"
milestone = "m1"
note = "So it works without a mouse. No key binding yet; maybe toggle_split_zoom unglues"
needs = ["#side-by-side"]

[[feature]]
id = "resize"
title = "Drag the line between the panes; the width is kept with the bond"
status = "todo"
note = "The line drags, and the window keeps the width until it closes; keeping it longer needs a field in dennet"
needs = ["#side-by-side"]

[[feature]]
id = "top-bottom"
title = "Glue one tab above or below another"
status = "dropped"
note = "Only side by side is wanted"

[[needs]]
on = "/deps/dennet#glue"
why = "The bond is kept on the Surface, so every window, and dense after a restart, shows the same combos"

[[needs]]
on = "/show/terminal"
why = "The first combos are two terminal tabs"
+++

A tab can be glued beside another tab of its Space. They stay two tabs,
two Surfaces, but they show together: whichever of the two is in front,
the terminal area shows both, split down the middle, with the glued tab
on the right. This is how a sidebar works, such as an agent's artifacts
next to its terminal, as Claude Desktop shows them.

In the tab bar the two handles are fused into one. Clicking its left half
puts the main tab in front, and its right half the glued one. Both stay in
view either way; only the focus moves.

Ghostty and Rex put splits inside a tab, and the tab bar shows only the
tab. Here each pane is its own tab, so the tab bar shows every Surface.
That replaces Ghostty's zoom: to give one pane the whole width, unglue the
two, and each becomes a plain tab, next to the other. To put them back,
glue them again. Any two tabs of a Space can be glued, not only a pair
that was unglued.

Only two tabs per combo for now; more is `t8y:/tabs/combo-many`. Only
side by side; top and bottom is not wanted.

## How it is built

`Space.combos` works out the combos from `spec.beside`. `SpaceTabs` keeps
one terminal per tab and, for a combo, puts both in one horizontal
`SplitTree` in the window; the focused pane's tab is the one in front.
The bond is not a split inside one tab's tree: a split there would hide
one tab from the tab bar.

A bond naming a Surface that has gone counts as no bond, so closing one
tab of a combo leaves the other as a plain tab, with nothing to clean up
in dennet.

## Decisions

- Words: glue and unglue. "Attach" and "detach" already mean `den attach`
  and the Close Tab sheet's Detach.
- ⌘ is the modifier. ⌘-drag a handle onto another tab to glue it there.
- ⌘-drag a half away from its combo to unglue it. It lands where it is
  dropped.
- A tab already in a combo can't be glued, or glued onto. Unglue first.
  For now; wider combos would change this.
- Go to Tab (⌘1, ⌘2, …), next and previous tab, and Go Back and Go
  Forward (⌘[, ⌘]) count a combo as one stop.
