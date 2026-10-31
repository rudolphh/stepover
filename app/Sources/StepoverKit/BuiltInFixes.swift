import Foundation

/// Fixes Stepover applies in every bottle, beneath the bottle's own settings in stepover.json
/// (a bottle's rule for the same program wins on graphics and environment; arguments add up).
/// Keyed by program file name, or by full Windows path where the file name is common; each says why it exists.
public enum BuiltInFixes {
    public struct Fix: Sendable {
        public let exe: String
        public let rule: ProcessRule
        /// A Windows compatibility mark (AppCompatFlags\Layers) for the program, written into the bottle's registry
        /// by BottleSetup.compatLayersPatch. Wine reads marks by lowercased file name, so only for fixes keyed by one.
        public var layers: String? = nil
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
        Fix(exe: "GTA5_Enhanced.exe", rule: ProcessRule(), layers: "~ HIGHDPIAWARE",
            why: "GTA V Enhanced picks its own DPI handling, and at 192 DPI in High Resolution Mode it then draws "
                + "itself twice its size. Marked DPI-aware, as Windows' compatibility settings do, it fills the screen; "
                + "at 96 DPI the mark changes nothing."),
    ]

    /// The fix for the program at `exe` inside a bottle, matched as the compat plug-in matches sections: by file
    /// name, or by full Windows path for a fix keyed by one (C:\... is <bottle>/drive_c/...).
    public static func fix(for exe: URL) -> Fix? {
        let path = exe.path.lowercased()
        return all.first { fix in
            let key = fix.exe.lowercased()
            guard key.hasPrefix(#"c:\"#) else { return exe.lastPathComponent.lowercased() == key }
            return path.hasSuffix("/drive_c/" + key.dropFirst(3).replacingOccurrences(of: #"\"#, with: "/"))
        }
    }
}
