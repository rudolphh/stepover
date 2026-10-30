import Foundation

/// Picks a graphics backend per program, the job CrossOver's compat database does: known games
/// first (settings proven on this Mac), then a look at the exe itself.
public enum GraphicsPicker {
    public struct Pick: Sendable {
        public var backend: Backend
        public var env: [String: String]
        public var reason: String
    }

    /// Known programs, keyed by lowercased exe file name.
    public static let known: [String: Pick] = [
        "rdr2.exe": Pick(backend: .d3dmetal, env: ["D3DM_ENABLE_METALFX": "1"],
                         reason: "Red Dead Redemption 2: DirectX 12 on D3DMetal, DLSS becomes MetalFX (Vulkan is rejected under Wine)"),
        "playrdr2.exe": Pick(backend: .d3dmetal, env: [:], reason: "Red Dead Redemption 2 launcher"),
        "lanoire.exe": Pick(backend: .dxmt, env: [:],
                            reason: "L.A. Noire: 32-bit DirectX 11, which D3DMetal cannot run; DXMT was fastest here"),
        "hi-fi-rush.exe": Pick(backend: .d3dmetal, env: [:], reason: "Hi-Fi Rush: DirectX 12 on D3DMetal"),
        "hibiki-win64-shipping.exe": Pick(backend: .d3dmetal, env: [:], reason: "Hi-Fi Rush game process"),
        "duckov.exe": Pick(backend: .d3dmetal, env: [:], reason: "Escape from Duckov: Unity DirectX 11 on D3DMetal"),
        "duckovlauncher.exe": Pick(backend: .d3dmetal, env: [:], reason: "Escape from Duckov resolution helper"),
    ]

    public static func pick(exe: URL) -> Pick {
        // A program's picked backend wins over a built-in fix's, so the two must agree.
        if let fix = BuiltInFixes.fix(for: exe), let backend = fix.rule.graphics {
            return Pick(backend: backend, env: [:], reason: fix.why)
        }
        let name = exe.lastPathComponent.lowercased()
        if let known = known[name] { return known }
        guard let pe = PEFile(url: exe) else {
            return Pick(backend: .d3dmetal, env: [:], reason: "could not read the exe; D3DMetal is the usual choice")
        }
        let imports = pe.imports
        let bits = pe.is64Bit ? "64-bit" : "32-bit"
        let dx12 = imports.contains("d3d12.dll")
        let dx11 = imports.contains("d3d11.dll") || imports.contains("dxgi.dll") || imports.contains("d3d10.dll") || imports.contains("d3d10_1.dll")
        let old = imports.contains("d3d9.dll") || imports.contains("d3d8.dll") || imports.contains("ddraw.dll") || imports.contains("opengl32.dll")

        if pe.is64Bit {
            if dx12 { return Pick(backend: .d3dmetal, env: [:], reason: "\(bits) DirectX 12: D3DMetal") }
            if dx11 { return Pick(backend: .d3dmetal, env: [:], reason: "\(bits) DirectX 11: D3DMetal (DXMT is the alternative)") }
            if old { return Pick(backend: .wined3d, env: [:], reason: "\(bits) DirectX 9 or older / OpenGL: WineD3D") }
            return Pick(backend: .d3dmetal, env: [:], reason: "\(bits), DirectX loaded at runtime: D3DMetal")
        }
        if dx11 { return Pick(backend: .dxmt, env: [:], reason: "\(bits) DirectX 10/11: DXMT (D3DMetal is 64-bit only)") }
        if old { return Pick(backend: .wined3d, env: [:], reason: "\(bits) DirectX 9 or older / OpenGL: WineD3D") }
        return Pick(backend: .dxmt, env: [:], reason: "\(bits), DirectX loaded at runtime: DXMT (D3DMetal is 64-bit only)")
    }
}
