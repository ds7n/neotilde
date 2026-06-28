// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// A parameter placeholder inside a macro body, written `${name}` or
/// `${name:default}` in a template. Resolved to text at fire-time: connection
/// placeholders (`${host}`/`${user}`/`${port}`) auto-fill from the live session;
/// any other name prompts the user, with the entered value remembered per host and
/// `defaultValue` (when present) pre-filling the prompt. A `nil` `defaultValue` means
/// "no default" (always prompt unless remembered); an empty-string default is an
/// explicit empty value. (keybar-customization spec "Optional placeholders".)
public struct MacroPlaceholder: Equatable, Sendable, Codable {
    public let name: String
    public let defaultValue: String?
    public init(name: String, defaultValue: String? = nil) {
        self.name = name
        self.defaultValue = defaultValue
    }
}

/// One element of a parameterized macro body: either a literal keystroke or a
/// placeholder to be resolved at fire-time. A plain recorded macro is all `.event`s;
/// a template macro may interleave `.placeholder`s. (Codable is added in the Macro
/// integration slice, alongside the legacy `[MacroEvent]` back-compat decode.)
public enum MacroBodyElement: Equatable, Sendable {
    case event(MacroEvent)
    case placeholder(MacroPlaceholder)
}
