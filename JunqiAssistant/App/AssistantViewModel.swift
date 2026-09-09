import Foundation
import Combine
import UIKit

@MainActor
final class AssistantViewModel: ObservableObject {
    @Published private(set) var statusText = "等待启动"
    @Published private(set) var ocrText = ""
    @Published private(set) var stepText = "未识别"
    @Published private(set) var knownPiecesText = "暂无"
    @Published private(set) var trajectoryText = "暂无轨迹"
    @Published private(set) var latestBoard: BoardSnapshot?
    @Published private(set) var inferenceText = "暂无候选情报"
    @Published private(set) var liveStateText = "棋局未初始化"
    @Published private(set) var confirmedPieces: [BoardPoint: PieceKind] = [:]
    @Published private(set) var enemyBacks: Set<BoardPoint> = []
    @Published private(set) var boardImportStatus = "棋谱未导入"
    @Published private(set) var isRunning = false

    @Published var leftOpponent = OpponentState()
    @Published var rightOpponent = OpponentState()
    @Published var events: [GameEvent] = []
    @Published var oursBoardRecord = ImportedBoardRecord.empty(owner: .ours)
    @Published var teammateBoardRecord = ImportedBoardRecord.empty(owner: .teammate)
    @Published var oursBoardImage: UIImage?
    @Published var teammateBoardImage: UIImage?

    let pip = PiPController()

    private let server = LocalFrameServer()
    private let analyzer = ScreenAnalyzer()
    private let inferenceEngine = InferenceEngine()
    private let gameStateEngine = GameStateEngine()
    private let keepAlive = BackgroundKeepAlive()
    private var currentStep: Int?
    private var latestOCRText = ""
    private var currentBoardSessionID: Int?

    init() {
        oursBoardRecord = BoardRecordPersistence.load(owner: .ours)
        teammateBoardRecord = BoardRecordPersistence.load(owner: .teammate)
        oursBoardImage = BoardImagePersistence.load(owner: .ours)
        teammateBoardImage = BoardImagePersistence.load(owner: .teammate)
        resetGameState()
        updateBoardImportStatus()
    }

    func start() {
        guard !isRunning else { return }

        do {
            analyzer.reset()
            currentBoardSessionID = nil
            resetGameState()
            try server.start(
                onStatus: { [weak self] text in
                    self?.statusText = text
                },
                onFrame: { [weak self] data in
                    self?.handleFrame(data)
                }
            )
            keepAlive.start()
            isRunning = true
            statusText = "等待控制中心开始录屏"
            pip.start()
            updateOverlay()
        } catch {
            statusText = "启动失败：\(error.localizedDescription)"
        }
    }

    func stop() {
        server.stop()
        keepAlive.stop()
        pip.stop()
        isRunning = false
        statusText = "已停止"
        updateOverlay()
    }

    func addEvent(_ event: GameEvent) {
        events.append(event)
        updateOverlay()
    }

    func clearEvents() {
        events.removeAll()
        resetGameState()
        updateOverlay()
    }

    func importBoardImage(_ image: UIImage, owner: BoardOwner) async {
        boardImportStatus = "正在识别\(owner.title)"
        do {
            let normalizedImage = image.normalizedForOCR()
            let record = try await BoardImageImporter.recognize(
                image: normalizedImage,
                owner: owner
            )
            if owner == .ours {
                oursBoardRecord = record
                oursBoardImage = normalizedImage
            } else {
                teammateBoardRecord = record
                teammateBoardImage = normalizedImage
            }
            BoardRecordPersistence.save(record)
            BoardImagePersistence.save(normalizedImage, owner: owner)
            resetGameState()
            boardImportStatus = "\(owner.title)：\(record.validation.statusText)"
        } catch {
            boardImportStatus = "\(owner.title)识别失败：\(error.localizedDescription)"
        }
    }

    func clearBoardRecord(owner: BoardOwner) {
        let record = ImportedBoardRecord.empty(owner: owner)
        if owner == .ours {
            oursBoardRecord = record
        } else {
            teammateBoardRecord = record
        }
        BoardRecordPersistence.save(record)
        BoardImagePersistence.delete(owner: owner)
        if owner == .ours {
            oursBoardImage = nil
        } else {
            teammateBoardImage = nil
        }
        resetGameState()
        boardImportStatus = "\(owner.title)已清空"
    }

    func saveBoardRecords() {
        BoardRecordPersistence.save(oursBoardRecord)
        BoardRecordPersistence.save(teammateBoardRecord)
        resetGameState()
        boardImportStatus = "已保存 · 我方\(oursBoardRecord.validation.statusText) · 队友\(teammateBoardRecord.validation.statusText)"
    }

    private func handleFrame(_ data: Data) {
        guard let pixelBuffer = data.toCVPixelBuffer() else {
            statusText = "收到画面但解码失败"
            return
        }

        Task {
            let snapshot = await analyzer.analyze(pixelBuffer: pixelBuffer)
            await MainActor.run {
                self.apply(snapshot)
            }
        }
    }

    private func apply(_ snapshot: ScreenSnapshot) {
        currentStep = snapshot.step
        latestOCRText = snapshot.rawText
        ocrText = snapshot.rawText
        stepText = snapshot.step.map { "第\($0)步" } ?? "未识别"
        knownPiecesText = summarize(pieces: snapshot.pieces)
        trajectoryText = summarize(board: snapshot.board)
        latestBoard = snapshot.board
        if let board = snapshot.board,
           board.sessionID != currentBoardSessionID {
            currentBoardSessionID = board.sessionID
            resetGameState()
        }
        if let board = snapshot.board, board.isReliable {
            let update = gameStateEngine.apply(board: board, step: snapshot.step)
            leftOpponent = update.leftOpponent
            rightOpponent = update.rightOpponent
            events.append(contentsOf: update.newEvents)
            liveStateText = "\(update.statusText) · 占位\(board.occupiedCount) 轨迹\(board.tracks.count) 移动\(board.moves.count)"
            confirmedPieces = gameStateEngine.confirmedPieces()
            enemyBacks = Set(
                board.tracks
                    .filter {
                        ($0.side == .leftEnemy || $0.side == .rightEnemy)
                            && $0.kind == nil
                    }
                    .map(\.current)
            )
        } else {
            if snapshot.board?.isSessionReady == false {
                liveStateText = "等待进入棋局，暂不记牌"
            } else {
                liveStateText = "棋盘跟踪短暂中断"
            }
            enemyBacks.removeAll()
        }
        statusText = snapshot.board == nil || snapshot.board?.isReliable == false
            ? (snapshot.rawText.isEmpty ? "录屏中，等待可识别文字" : "正在分析")
            : "棋盘跟踪中"
        updateOverlay()
    }

    private func updateOverlay() {
        let leftInferences = inferenceEngine.infer(
            opponent: leftOpponent,
            side: .left,
            events: events
        )
        let rightInferences = inferenceEngine.infer(
            opponent: rightOpponent,
            side: .right,
            events: events
        )

        let candidateLines = (leftInferences + rightInferences)
            .prefix(3)
            .map { inference in
                let pieces = inference.candidates.prefix(3).map {
                    "\($0.kind.name)\(Int(($0.probability * 100).rounded()))%"
                }
                return "\(inference.side.title)\(inference.contactID) " + pieces.joined(separator: " ")
            }

        let eventText = eventSummary()
        inferenceText = candidateLines.isEmpty
            ? "\(eventText)\n\(trajectoryText)"
            : "\(eventText)\n" + candidateLines.joined(separator: "\n")

        let overlayCandidates = candidateLines.isEmpty
            ? [liveStateText, trajectoryText]
            : Array(candidateLines.prefix(3))

        pip.update(
            state: OverlayState(
                statusText: statusText,
                step: currentStep,
                ocrPreview: latestOCRText,
                leftSummary: remainingPiecesSummary(for: leftOpponent),
                rightSummary: remainingPiecesSummary(for: rightOpponent),
                eventText: eventText,
                candidates: overlayCandidates
            )
        )
    }

    private func remainingPiecesSummary(for opponent: OpponentState) -> String {
        let displayOrder: [PieceKind] = [
            .commander,
            .armyCommander,
            .divisionCommander,
            .brigadeCommander,
            .regimentCommander,
            .battalionCommander,
            .companyCommander,
            .platoonCommander,
            .engineer,
            .mine,
            .bomb,
            .flag
        ]

        let items = displayOrder.map { kind -> String in
            let count = opponent.remainingCount(for: kind)
            return "\(kind.shortName)\(count)"
        }

        let firstLine = items.prefix(6).joined(separator: " ")
        let secondLine = items.dropFirst(6).joined(separator: " ")
        return [firstLine, secondLine]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func eventSummary() -> String {
        guard let event = events.last else {
            return liveStateText
        }

        let enemyName = event.contactID
        return "\(event.side.title)\(enemyName) \(event.ourPiece.name) → \(event.result.title)"
    }

    private func summarize(pieces: [DetectedPiece]) -> String {
        guard !pieces.isEmpty else { return "暂无" }
        let counts = Dictionary(grouping: pieces, by: \.kind).mapValues { $0.count }
        return PieceKind.allCases.compactMap { kind in
            guard let count = counts[kind] else { return nil }
            return "\(kind.name)\(count)"
        }
        .joined(separator: "  ")
    }

    private func summarize(board: BoardSnapshot?) -> String {
        guard let board else { return "暂无轨迹" }
        if !board.isSessionReady {
            return "等待进入棋局 · 稳定确认\(board.stabilityProgress)/8"
        }
        let source = board.usedFallbackRect ? "自动回退" : "视觉定位"
        let tracking = "\(source) · 占位\(board.occupiedCount) 轨迹\(board.tracks.count)"
        if board.occupiedCount < 60 || board.occupiedCount > 150 {
            return "\(tracking)：正在校准"
        }
        let sideSummary = BoardSide.allCases.compactMap { side -> String? in
            guard let count = board.sideCounts[side], count > 0 else { return nil }
            return "\(side.title)\(count)"
        }
        .joined(separator: " ")

        guard !board.moves.isEmpty else {
            return "\(tracking) · \(sideSummary)"
        }

        return board.moves.prefix(4).map { move in
            let name = move.kind?.name ?? move.trackID
            return "\(move.side.title)\(name) \(move.from)→\(move.to)"
        }
        .joined(separator: "；")
    }

    private func updateBoardImportStatus() {
        let ours = oursBoardRecord.occupiedCount
        let teammate = teammateBoardRecord.occupiedCount
        if ours == 0, teammate == 0 {
            boardImportStatus = "棋谱未导入"
        } else {
            boardImportStatus = "我方\(oursBoardRecord.validation.statusText) · 队友\(teammateBoardRecord.validation.statusText)"
        }
    }

    private func resetGameState() {
        gameStateEngine.reset(
            ours: oursBoardRecord,
            teammate: teammateBoardRecord
        )
        leftOpponent.reset()
        rightOpponent.reset()
        events.removeAll()
        liveStateText = "棋局已初始化，等待实时识别"
        confirmedPieces = gameStateEngine.confirmedPieces()
        enemyBacks.removeAll()
    }
}

