import Foundation

/// Why adding a game stopped (spec D9).
public enum InstallFailure: Codable, Hashable, Sendable {
    case installerError(String?), damaged, stoppedResponding, noGame, nothing, folderGone, archive, stillDownloading, interrupted

    /// One plain sentence for the tile.
    public var text: String {
        switch self {
        case .installerError(let message?):
            var trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            while trimmed.hasSuffix(".") { trimmed.removeLast() }
            return "The installer stopped with an error: \(trimmed)."
        case .installerError(nil): return "The installer stopped with an error."
        case .damaged: return "Some of the installer's files are damaged. Download them again, then Try Again."
        case .stoppedResponding: return "The installer stopped responding."
        case .noGame: return "Installed, but Stepover couldn't tell which program is the game."
        case .nothing: return "This folder doesn't have an installer or a game in it."
        case .folderGone: return "The folder isn't there anymore."
        case .archive: return "Unpack it first, then drag in the folder."
        case .stillDownloading: return "This folder is still downloading. Try Again when it's done."
        case .interrupted: return "Interrupted"
        }
    }
}

/// Where adding a game is, in the words its tile shows (spec D3, D9, D11).
public enum InstallStage: Codable, Hashable, Sendable {
    case waiting, confirm, alreadyInLibrary(String), gettingReady, copying(done: Int64, total: Int64), installing(written: Int64),
         needsYou, addingComponents, findingGame, paused, failed(InstallFailure), done(addOnFailed: String?)

    public var text: String {
        switch self {
        case .waiting: return "Waiting to install"
        case .confirm: return "Not installed yet"
        case .alreadyInLibrary: return "Already in your Library"
        case .gettingReady: return "Getting ready"
        case .copying(let done, let total): return "Copying, \(Self.gigabytes(done)) of \(Self.gigabytes(total))"
        case .installing(let written):
            return written < 1_000_000_000 ? "Installing" : "Installing (\(Self.gigabytes(written)) so far)"
        case .needsYou: return "The installer needs you: it's open on the Mac"
        case .addingComponents: return "Adding what the game needs"
        case .findingGame: return "Finding the game"
        case .paused: return "Paused: the disk is nearly full. Free up some space and it carries on."
        case .failed(let failure): return failure.text
        case .done(let addOn?): return "Ready; the \(addOn) add-on didn't install"
        case .done(nil): return "Ready"
        }
    }

    /// Stepover is working on it (or holding it paused).
    public var isActive: Bool {
        switch self {
        case .gettingReady, .copying, .installing, .needsYou, .addingComponents, .findingGame, .paused: return true
        default: return false
        }
    }

    /// Whole gigabytes, as the tile says them: "12 GB".
    public static func gigabytes(_ bytes: Int64) -> String { "\(max(Int64(1), (bytes + 500_000_000) / 1_000_000_000)) GB" }
}
