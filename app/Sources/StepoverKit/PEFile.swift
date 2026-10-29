import Foundation

/// Just enough of the Windows PE format to pick a graphics backend and pull out an icon.
public struct PEFile {
    public enum Machine { case i386, x86_64, other(UInt16) }

    public let machine: Machine
    /// Lowercased DLL names from the import and delay-import tables.
    public let imports: Set<String>
    /// The optional header's Subsystem: 2 is a windowed program, 3 a console one.
    public let subsystem: UInt16
    /// The COFF header's Characteristics.
    public let characteristics: UInt16
    let data: Data
    let sections: [(va: UInt32, size: UInt32, raw: UInt32)]
    let resourceRVA: UInt32

    public var is64Bit: Bool { if case .x86_64 = machine { return true }; return false }
    public var isWindowed: Bool { subsystem == 2 }
    /// IMAGE_FILE_LARGE_ADDRESS_AWARE: a 32-bit program allowed above 2 GB (what freezes unarc; spec Appendix A).
    public var isLargeAddressAware: Bool { characteristics & 0x20 != 0 }

    public init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count > 0x40 else { return nil }
        self.data = data
        func u16(_ o: Int) -> UInt16? { o + 2 <= data.count ? UInt16(data[o]) | UInt16(data[o + 1]) << 8 : nil }
        func u32(_ o: Int) -> UInt32? { o + 4 <= data.count ? (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[o + $1]) << (8 * $1) } : nil }

        guard u16(0) == 0x5A4D, let peOffset = u32(0x3C).map(Int.init), u32(peOffset) == 0x4550,
              let machineRaw = u16(peOffset + 4), let sectionCount = u16(peOffset + 6),
              let optSize = u16(peOffset + 20), let magic = u16(peOffset + 24) else { return nil }
        machine = machineRaw == 0x14c ? .i386 : machineRaw == 0x8664 ? .x86_64 : .other(machineRaw)
        characteristics = u16(peOffset + 22) ?? 0
        let opt = peOffset + 24
        subsystem = u16(opt + 68) ?? 0
        let dirs = opt + (magic == 0x20b ? 112 : 96)
        func dir(_ index: Int) -> UInt32 { u32(dirs + index * 8) ?? 0 }

        var secs: [(va: UInt32, size: UInt32, raw: UInt32)] = []
        let table = opt + Int(optSize)
        for i in 0..<Int(sectionCount) {
            let s = table + i * 40
            guard let vsize = u32(s + 8), let va = u32(s + 12), let rawSize = u32(s + 16), let raw = u32(s + 20) else { break }
            secs.append((va, max(vsize, rawSize), raw))
        }

        func offset(_ rva: UInt32) -> Int? {
            for s in secs where rva >= s.va && rva < s.va &+ s.size { return Int(rva - s.va + s.raw) }
            return nil
        }
        func cString(_ rva: UInt32) -> String? {
            guard let start = offset(rva) else { return nil }
            var end = start
            while end < data.count, data[end] != 0, end - start < 256 { end += 1 }
            return String(decoding: data[start..<end], as: UTF8.self)
        }
        var names = Set<String>()
        if let start = offset(dir(1)) {  // IMAGE_IMPORT_DESCRIPTOR, 20 bytes each, name RVA at +12
            var d = start
            while let nameRVA = u32(d + 12), nameRVA != 0, names.count < 512 {
                if let name = cString(nameRVA) { names.insert(name.lowercased()) }
                d += 20
            }
        }
        if let start = offset(dir(13)) {  // delay imports, 32 bytes each, name RVA at +4
            var d = start
            while let nameRVA = u32(d + 4), nameRVA != 0, names.count < 512 {
                if let name = cString(nameRVA) { names.insert(name.lowercased()) }
                d += 32
            }
        }
        imports = names
        sections = secs
        resourceRVA = dir(2)
    }

    // MARK: icon

    /// The exe's icon, or, for helpers without one (e.g. a small launcher), the largest icon-bearing
    /// exe in the same folder.
    public static func icon(for exe: URL) -> Data? {
        if let data = PEFile(url: exe)?.iconData() { return data }
        let siblings = (try? FileManager.default.contentsOfDirectory(at: exe.deletingLastPathComponent(),
                                                                     includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return siblings
            .filter { $0.pathExtension.lowercased() == "exe" && !$0.lastPathComponent.lowercased().hasPrefix("unins")
                && !$0.lastPathComponent.lowercased().contains("crashhandler") }
            .sorted { ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            .lazy.compactMap { PEFile(url: $0)?.iconData() }.first
    }

    func offset(_ rva: UInt32) -> Int? {
        for s in sections where rva >= s.va && rva < s.va &+ s.size { return Int(rva - s.va + s.raw) }
        return nil
    }
    func u16(_ o: Int) -> UInt16 { o + 2 <= data.count ? UInt16(data[o]) | UInt16(data[o + 1]) << 8 : 0 }
    func u32(_ o: Int) -> UInt32 { o + 4 <= data.count ? (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[o + $1]) << (8 * $1) } : 0 }

    /// Resource directory entries (id or name offset, target offset relative to the resource root, isDir)
    func entries(_ dirOffset: Int, base: Int) -> [(id: UInt32, target: Int, isDir: Bool)] {
        let count = Int(u16(dirOffset + 12)) + Int(u16(dirOffset + 14))
        return (0..<min(count, 4096)).map { i in
            let e = dirOffset + 16 + i * 8
            let target = u32(e + 4)
            return (u32(e), base + Int(target & 0x7fff_ffff), target & 0x8000_0000 != 0)
        }
    }

    /// First data blob below a resource directory node (any name, any language).
    func firstData(_ node: (id: UInt32, target: Int, isDir: Bool), base: Int) -> Data? {
        var current = node
        while current.isDir {
            guard let next = entries(current.target, base: base).first else { return nil }
            current = next
        }
        let rva = u32(current.target), size = Int(u32(current.target + 4))
        guard let start = offset(rva), start + size <= data.count, size > 0 else { return nil }
        return data.subdata(in: start..<start + size)
    }

    /// The version resource's ProductName ("Tiny Game" for an Inno Setup installer made for it).
    public var productName: String? {
        guard resourceRVA != 0, let base = offset(resourceRVA),
              let versionType = entries(base, base: base).first(where: { $0.id == 16 && $0.isDir }),   // RT_VERSION
              let first = entries(versionType.target, base: base).first,
              let blob = firstData(first, base: base) else { return nil }
        let key = Data("ProductName".utf16.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] } + [0, 0])
        guard let found = blob.range(of: key) else { return nil }
        // The value follows the key's terminator, padded to a 4-byte boundary, as UTF-16 up to a 0 character.
        var at = (found.upperBound - blob.startIndex + 3) & ~3
        var units: [UInt16] = []
        while at + 1 < blob.count {
            let unit = UInt16(blob[blob.startIndex + at]) | UInt16(blob[blob.startIndex + at + 1]) << 8
            if unit == 0 { break }
            units.append(unit)
            at += 2
        }
        let name = String(decoding: units, as: UTF16.self).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// The same file with IMAGE_FILE_LARGE_ADDRESS_AWARE (0x20) cleared in the COFF characteristics; nil if it isn't a
    /// Windows program. Spec Appendix A: the copy of an installer's setup.tmp that doesn't freeze unarc.
    public static func clearingLargeAddressAware(_ data: Data) -> Data? {
        func u16(_ o: Int) -> Int? { o + 2 <= data.count ? Int(data[data.startIndex + o]) | Int(data[data.startIndex + o + 1]) << 8 : nil }
        guard u16(0) == 0x5A4D, let low = u16(0x3C), let high = u16(0x3E) else { return nil }
        let pe = low | high << 16
        guard u16(pe) == 0x4550, u16(pe + 2) == 0, let flags = u16(pe + 22) else { return nil }
        var out = data
        out[out.startIndex + pe + 22] = UInt8(flags & 0xff & ~0x20)
        return out
    }

    /// The program's main icon group as .ico file data.
    public func iconData() -> Data? {
        guard resourceRVA != 0, let base = offset(resourceRVA) else { return nil }
        let types = entries(base, base: base)
        guard let groupType = types.first(where: { $0.id == 14 && $0.isDir }),   // RT_GROUP_ICON
              let iconType = types.first(where: { $0.id == 3 && $0.isDir }),    // RT_ICON
              let firstGroup = entries(groupType.target, base: base).first,
              let group = firstData(firstGroup, base: base), group.count >= 6 else { return nil }
        let icons = Dictionary(entries(iconType.target, base: base).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let count = Int(UInt16(group[4]) | UInt16(group[5]) << 8)
        var images: [(header: Data, image: Data)] = []
        for i in 0..<count {
            let e = 6 + i * 14
            guard e + 14 <= group.count else { break }
            let id = UInt32(UInt16(group[e + 12]) | UInt16(group[e + 13]) << 8)
            guard let node = icons[id], let image = firstData(node, base: base) else { continue }
            images.append((group.subdata(in: e..<e + 8), image))  // width..bitCount, then size/offset below
        }
        guard !images.isEmpty else { return nil }
        var ico = Data([0, 0, 1, 0, UInt8(images.count & 0xff), UInt8(images.count >> 8)])
        var dataOffset = 6 + images.count * 16
        func le32(_ v: Int) -> Data { Data((0..<4).map { UInt8((v >> (8 * $0)) & 0xff) }) }
        for img in images {
            ico.append(img.header); ico.append(le32(img.image.count)); ico.append(le32(dataOffset))
            dataOffset += img.image.count
        }
        for img in images { ico.append(img.image) }
        return ico
    }
}
