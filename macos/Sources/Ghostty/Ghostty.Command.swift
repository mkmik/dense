import GhosttyKit

extension Ghostty {
    /// `ghostty_command_s`
    struct Command: Sendable {
        /// The title of the command.
        let title: String

        /// Human-friendly description of what this command will do.
        let description: String

        /// The full action that must be performed to invoke this command.
        let action: String

        /// Only the key portion of the action so you can compare action types, e.g. `goto_split`
        /// instead of `goto_split:left`.
        let actionKey: String

        /// True if this can be performed on this target.
        var isSupported: Bool {
            !Self.unsupportedActionKeys.contains(actionKey) && !Self.unsupportedActions.contains(action)
        }

        /// dense: whole actions that mean nothing here. Its tabs are a Space's, not macOS
        /// window tabs, so closing the others or the ones to the right does nothing useful;
        /// Close Tab itself goes to the Space's tab.
        static let unsupportedActions: [String] = [
            "close_tab:other",
            "close_tab:right",
        ]

        /// Unsupported action keys, because they either don't make sense in the context of our
        /// target platform or they just aren't implemented yet.
        static let unsupportedActionKeys: [String] = [
            "toggle_tab_overview",
            "toggle_window_decorations",
            "prompt_window_title",
            "show_gtk_inspector",
            // dense: a split isn't a den, so its shell is gone on quit. See BaseTerminalController.newSplit.
            "new_split",
            // With no splits, there is nothing to move to, zoom or equalize.
            "goto_split",
            "toggle_split_zoom",
            "equalize_splits",
            "resize_split",
        ]

        init(cValue: ghostty_command_s) {
            self.title = String(cString: cValue.title)
            self.description = String(cString: cValue.description)
            self.action = String(cString: cValue.action)
            self.actionKey = String(cString: cValue.action_key)
        }
    }
}
