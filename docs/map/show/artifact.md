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
on = "/show/web#page"
why = "An html web tab can draw the artifact; native SwiftUI from A2UI is the other way"
+++

The reason for combo tabs. Not designed yet.
