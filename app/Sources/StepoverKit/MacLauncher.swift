import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Per-program Mac apps in Paths.launchers that start the program through `stepover run`.
public enum MacLauncher {
    public static func appURL(for program: Program) -> URL {
        Paths.launchers.appendingPathComponent("\(safeName(program.name)).app")
    }

    /// Stepover.app's bundle identifier (the command inside the app shares it); launchers derive theirs from it.
    static var appIdentifier: String { Paths.appBundle?.bundleIdentifier ?? "io.github.rudolphh.stepover" }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func safeName(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    @discardableResult
    public static func create(for program: Program, in bottle: Bottle) throws -> URL {
        let fm = FileManager.default
        let app = appURL(for: program)
        let contents = app.appendingPathComponent("Contents")
        try? fm.removeItem(at: app)
        try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)

        let slug = program.name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let plist: [String: Any] = [
            "CFBundleIdentifier": "\(appIdentifier).launcher.\(slug)",
            "CFBundleName": program.name,
            "CFBundleDisplayName": program.name,
            "CFBundleExecutable": "launch",
            "CFBundlePackageType": "APPL",
            "CFBundleIconFile": "AppIcon",
            "CFBundleShortVersionString": "1.0",
            "LSUIElement": true,  // it only hands off to Wine and exits; the game brings its own Dock icon
            "StepoverBottle": bottle.name,
            "StepoverProgram": program.name,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        let script = """
        #!/bin/sh
        # Made by Stepover: starts "\(program.name)" in the "\(bottle.name)" bottle.
        # Finds Stepover where it was when this launcher was made, else in the usual places.
        for cli in "${STEPOVER_CLI:-}" \(shellQuote(Paths.cli.path)) /Applications/Stepover.app/Contents/MacOS/stepover-cli \\
                   "$HOME/Applications/Stepover.app/Contents/MacOS/stepover-cli"; do
            [ -n "$cli" ] && [ -x "$cli" ] && exec "$cli" run \(shellQuote(bottle.name)) \(shellQuote(program.name))
        done
        app=$(/usr/bin/mdfind "kMDItemCFBundleIdentifier == '\(appIdentifier)'" | head -n 1)
        [ -n "$app" ] && exec "$app/Contents/MacOS/stepover-cli" run \(shellQuote(bottle.name)) \(shellQuote(program.name))
        /usr/bin/osascript -e 'display alert "Stepover is not installed" message "Install Stepover to start this game."'
        exit 1

        """
        let exec = contents.appendingPathComponent("MacOS/launch")
        try script.write(to: exec, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exec.path)

        if let exe = WindowsPath.toMac(program.exe, bottle: bottle), let ico = PEFile.icon(for: exe) {
            try? writeICNS(fromICO: ico, to: contents.appendingPathComponent("Resources/AppIcon.icns"))
        }
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", app.path]
        sign.standardError = FileHandle.nullDevice
        try? sign.run(); sign.waitUntilExit()
        NSWorkspace.shared.noteFileSystemChanged(app.path)
        return app
    }

    /// Converts the largest image of an .ico into a multi-size .icns.
    static func writeICNS(fromICO ico: Data, to url: URL) throws {
        guard let source = CGImageSourceCreateWithData(ico as CFData, nil) else { throw StepoverError.message("unreadable icon") }
        var best: CGImage?
        for i in 0..<CGImageSourceGetCount(source) {
            if let image = CGImageSourceCreateImageAtIndex(source, i, nil), image.width > (best?.width ?? 0) { best = image }
        }
        guard let image = best,
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.icns.identifier as CFString, 5, nil) else {
            throw StepoverError.message("could not write \(url.path)")
        }
        for size in [16, 32, 128, 256, 512] {
            guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            if let scaled = ctx.makeImage() { CGImageDestinationAddImage(dest, scaled, nil) }
        }
        guard CGImageDestinationFinalize(dest) else { throw StepoverError.message("could not write \(url.path)") }
    }
}
