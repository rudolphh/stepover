/// Fixes Stepover applies in every bottle, beneath the bottle's own settings in stepover.json
/// (a bottle's rule for the same program wins on graphics and environment; arguments add up).
/// Keyed by program file name, or by full Windows path where the file name is common; each says why it exists.
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
        Fix(exe: #"C:\Program Files\Rockstar Games\Launcher\Launcher.exe"#,
            rule: ProcessRule(graphics: .wined3d, env: ["WINE_D3D_CONFIG": "renderer=gl"]),
            why: "Rockstar Games Launcher needs Direct3D 10.1: D3DMetal doesn't offer it, and DXVK and wined3d's "
                + "Vulkan renderer need geometry shaders MoltenVK lacks. wined3d on OpenGL draws it."),
        Fix(exe: "SocialClubHelper.exe", rule: ProcessRule(args: ["--in-process-gpu"]),
            why: "Rockstar's Social Club window is Chromium like Steam's and stays blank for the same reason."),
    ]
}
