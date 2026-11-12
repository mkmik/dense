+++
title = "Artifact viewer"
summary = "Shows an agent's artifact in a tab glued beside the agent's terminal"
kind = "code"
intent = "aspiration"
research = "deferred"
refs = ["https://developers.googleblog.com/a2ui-10-build-delightful-fast-reliable-agentic-experiences/"]

[[needs]]
on = "/tabs/combo"
why = "It opens glued to the agent's tab, as Claude Desktop shows artifacts"

[[needs]]
fuzzy = "a Surface kind in dennet for content that is not a terminal"
why = "Today the only kind is terminal"

[[needs]]
fuzzy = "a renderer: an embedded web view, or native SwiftUI from A2UI"
why = "Something has to draw the artifact"
+++

The reason for combo tabs. Not designed yet.
