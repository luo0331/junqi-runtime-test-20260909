import CoreGraphics
import Foundation

enum PieceKind: String, CaseIterable, Codable, Identifiable, Hashable {
    case flag
    case commander
    case armyCommander
    case divisionCommander
    case brigadeCommander
    case regimentCommander
    case battalionCommander
    case companyCommander
    case platoonCommander
    case engineer
    case mine
    case bomb

    var id: String { rawValue }

    var name: String {
        switch self {
        case .flag: return "军旗"
        case .commander: return "司令"
        case .armyCommander: return "军长"
        case .divisionCommander: return "师长"
        case .brigadeCommander: return "旅长"
        case .regimentCommander: return "团长"
        case .battalionCommander: return "营长"
        case .companyCommander: return "连长"
        case .platoonCommander: return "排长"
        case .engineer: return "工兵"
        case .mine: return "地雷"
        case .bomb: return "炸弹"
        }
    }

    var shortName: String {
        switch self {
        case .flag: return "旗"
        case .commander: return "司"
        case .armyCommander: return "军"
        case .divisionCommander: return "师"
        case .brigadeCommander: return "旅"
        case .regimentCommander: return "团"
        case .battalionCommander: return "营"
        case .companyCommander: return "连"
        case .platoonCommander: return "排"
        case .engineer: return "兵"
        case .mine: return "雷"
        case .bomb: return "炸"
        }
    }

    var totalCount: Int {
        switch self {
        case .commander, .armyCommander, .flag: return 1
        case .divisionCommander, .brigadeCommander, .regimentCommander, .battalionCommander, .bomb: return 2
        case .companyCommander, .platoonCommander, .engineer, .mine: return 3
        }
    }

    var rank: Int {
        switch self {
        case .commander: return 13
        case .armyCommander: return 12
        case .divisionCommander: return 11
        case .brigadeCommander: return 10
        case .regimentCommander: return 9
        case .battalionCommander: return 8
        case .companyCommander: return 7
        case .platoonCommander: return 6
        case .engineer: return 5
        case .mine: return 1
        case .flag: return 0
        case .bomb: return 0
        }
    }

    var movable: Bool {
        switch self {
        case .flag, .mine: return false
        default: return true
        }
    }

    var aliases: [String] {
        switch self {
        case .flag: return ["军旗", "旗"]
        case .commander: return ["司令", "司"]
        case .armyCommander: return ["军长", "军"]
        case .divisionCommander: return ["师长", "师"]
        case .brigadeCommander: return ["旅长", "旅"]
        case .regimentCommander: return ["团长", "团"]
        case .battalionCommander: return ["营长", "营"]
        case .companyCommander: return ["连长", "连"]
        case .platoonCommander: return ["排长", "排"]
        case .engineer: return ["工兵", "兵"]
        case .mine: return ["地雷", "雷"]
        case .bomb: return ["炸弹", "炸", "弹"]
        }
    }

    static func match(_ text: String) -> [PieceKind] {
        let normalized = text.replacingOccurrences(of: " ", with: "")
        guard !normalized.isEmpty else { return [] }

        var result = Set<PieceKind>()
        for kind in PieceKind.allCases {
            for alias in kind.aliases {
                if normalized == alias {
                    result.insert(kind)
                    break
                }

                if alias.count >= 2, normalized.hasPrefix(alias) {
                    let suffix = normalized.dropFirst(alias.count)
                    if !suffix.isEmpty, suffix.allSatisfy({ $0.isNumber }) {
                        result.insert(kind)
                        break
                    }
                }
            }
        }
        return Array(result)
    }
}

enum EnemySide: String, CaseIterable, Codable, Identifiable {
    case left
    case right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .left: return "左侧敌方"
        case .right: return "右侧敌方"
        }
    }
}

struct OpponentState: Codable {
    var dead: [PieceKind: Int] = [:]
    var revealed: [PieceKind: Int] = [:]
    var unknownDead: Int = 0

    func count(_ kind: PieceKind, in dictionary: [PieceKind: Int]) -> Int {
        dictionary[kind, default: 0]
    }

    func deadCount(_ kind: PieceKind) -> Int {
        count(kind, in: dead)
    }

    func revealedCount(_ kind: PieceKind) -> Int {
        count(kind, in: revealed)
    }

    func unknownCount(_ kind: PieceKind) -> Int {
        max(0, kind.totalCount - deadCount(kind) - revealedCount(kind))
    }

    var unknownTotal: Int {
        PieceKind.allCases.reduce(0) { $0 + unknownCount($1) }
    }

    var remainingCount: Int {
        max(0, unknownTotal - unknownDead)
    }

    func remainingCount(for kind: PieceKind) -> Int {
        let knownAlive = max(0, kind.totalCount - deadCount(kind))
        let unknownAlive = effectiveUnknownCount(kind)
        return min(
            knownAlive,
            max(0, Int(unknownAlive.rounded()) + revealedCount(kind))
        )
    }

    func effectiveUnknownCount(_ kind: PieceKind) -> Double {
        let base = Double(unknownCount(kind))
        guard unknownTotal > 0 else { return 0 }
        return base * Double(remainingCount) / Double(unknownTotal)
    }

    mutating func setDead(_ kind: PieceKind, count: Int) {
        dead[kind] = min(max(0, count), kind.totalCount)
    }

    mutating func setRevealed(_ kind: PieceKind, count: Int) {
        revealed[kind] = min(max(0, count), kind.totalCount)
    }

    mutating func markDead(_ kind: PieceKind) {
        setDead(kind, count: deadCount(kind) + 1)
        setRevealed(kind, count: max(0, revealedCount(kind) - 1))
    }

    mutating func markUnknownDead() {
        unknownDead += 1
    }

    mutating func reset() {
        dead.removeAll()
        revealed.removeAll()
        unknownDead = 0
    }
}

struct GameEvent: Identifiable, Codable, Hashable {
    enum Source: String, Codable, CaseIterable {
        case enemyMoved
        case enemyStationary
        case unknown

        var title: String {
            switch self {
            case .enemyMoved: return "敌方主动吃我方"
            case .enemyStationary: return "我方主动碰敌方"
            case .unknown: return "不确定"
            }
        }
    }

    enum Result: String, Codable, CaseIterable {
        case enemySurvived
        case bothDead
        case enemyDeadOursSurvived
        case enemyDeadUnknown

        var title: String {
            switch self {
            case .enemySurvived: return "敌方存活，我方被吃"
            case .bothDead: return "双方同归于尽"
            case .enemyDeadOursSurvived: return "敌方被吃，我方存活"
            case .enemyDeadUnknown: return "敌方被吃，我方结果不确定"
            }
        }
    }

    var id: UUID = UUID()
    var side: EnemySide
    var contactID: String
    var ourPiece: PieceKind
    var source: Source
    var result: Result
    var createdAt: Date = Date()
}

struct DetectedPiece: Identifiable {
    var id: UUID = UUID()
    var kind: PieceKind
    var text: String
    var normalizedRect: CGRect
}

struct BoardPoint: Hashable, Codable, CustomStringConvertible {
    var row: Int
    var col: Int

    var description: String {
        "\(row + 1),\(col + 1)"
    }
}

enum BoardSide: String, CaseIterable, Codable {
    case ours
    case teammate
    case leftEnemy
    case rightEnemy
    case center

    var title: String {
        switch self {
        case .ours: return "我方"
        case .teammate: return "队友"
        case .leftEnemy: return "左敌"
        case .rightEnemy: return "右敌"
        case .center: return "中央"
        }
    }
}

enum GameScreenPhase: String {
    case idle
    case matching
    case matched
    case starting
    case playing

    var title: String {
        switch self {
        case .idle: return "等待匹配"
        case .matching: return "正在匹配"
        case .matched: return "已配对，等待对战"
        case .starting: return "对局开始，建立基准"
        case .playing: return "对局进行中"
        }
    }
}

struct BoardMove: Identifiable {
    var id = UUID()
    var trackID: String
    var from: BoardPoint
    var to: BoardPoint
    var side: BoardSide
    var kind: PieceKind?
}

struct BoardTrack: Identifiable {
    var id: String
    var current: BoardPoint
    var history: [BoardPoint]
    var side: BoardSide
    var kind: PieceKind?
    var lastSeenFrame: Int
}

struct BoardSnapshot {
    var frameIndex: Int
    var sessionID: Int
    var isSessionReady: Bool
    var stabilityProgress: Int
    var gamePhase: GameScreenPhase
    var boardRect: CGRect
    var imageWidth: Int
    var imageHeight: Int
    var ourOccupiedCount: Int
    var looksLikeGameBoard: Bool
    var isReliable: Bool
    var occupiedCount: Int
    var recognizedCount: Int
    var usedFallbackRect: Bool
    var scoreMinimum: Double
    var scoreMaximum: Double
    var occupancyThreshold: Double
    var sideCounts: [BoardSide: Int]
    var tracks: [BoardTrack]
    var moves: [BoardMove]
}

struct ScreenSnapshot {
    var step: Int?
    var rawText: String
    var pieces: [DetectedPiece]
    var board: BoardSnapshot?
    var capturedAt: Date
}

struct OverlayState {
    var statusText: String
    var step: Int?
    var ocrPreview: String
    var leftSummary: String
    var rightSummary: String
    var eventText: String
    var candidates: [String]

    static let idle = OverlayState(
        statusText: "等待录屏画面",
        step: nil,
        ocrPreview: "等待 OCR 画面",
        leftSummary: "左侧：未识别",
        rightSummary: "右侧：未识别",
        eventText: "等待棋局事件",
        candidates: ["启动录屏后自动分析"]
    )
}




