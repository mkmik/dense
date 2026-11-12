+++
title = "Terminal"
summary = "A Ghostty terminal running den attach to the Surface's Den"
kind = "code"
intent = "goal"
research = "done"
status = "done"
refs = ["macos/Sources/Features/Dense/SpaceTabs.swift"]

[[needs]]
on = "/deps/dennet#api"
why = "Reads the Surface and waits for its Den to run"

[[needs]]
on = "/deps/den"
why = "The terminal runs den attach"
+++
