import Foundation
import GamesListBuilder

FileHandle.standardError.write(Data("usage: games-list build --fixes <dir> --out <file> [--previous <file>] | verify <file>\n".utf8))
exit(2)
