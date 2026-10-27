/// Fixes Stepover applies in every bottle, beneath the bottle's own settings in stepover.json
/// (a bottle's rule for the same program wins on graphics and environment; arguments add up).
/// Keyed by program file name; each says why it exists.
public enum BuiltInFixes {
    public struct Fix: Sendable {
        public let exe: String
        public let rule: ProcessRule
        public let why: String
    }

    public static let all: [Fix] = [
        Fix(exe: "steamwebhelper.exe", rule: ProcessRule(args: ["--in-process-gpu"]),
            why: "Steam's browser draws from its GPU process into a window the main process owns, and Wine's "
                + "Mac driver drops drawing across processes, so the Steam window stays black."),
    ]
}
