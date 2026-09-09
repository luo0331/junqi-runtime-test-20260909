import Foundation

struct GameStateUpdate {
    var leftOpponent: OpponentState
    var rightOpponent: OpponentState
    var newEvents: [GameEvent]
    var statusText: String
}

private struct LivePiece {
    var id: String
    var side: BoardSide
    var kind: PieceKind?
    var position: BoardPoint?
    var trackID: String?
    var isRevealed: Bool
    var isDead: Bool
}

/// 把导入棋谱、实时轨迹和吃子结果合并成可持续更新的棋局状态。
final class GameStateEngine {
    private var pieces: [String: LivePiece] = [:]
    private var trackToPiece: [String: String] = [:]
    private var positionToPiece: [BoardPoint: String] = [:]
    private var previousTracks: [String: BoardTrack] = [:]
    private var previousTracksByPosition: [BoardPoint: BoardTrack] = [:]
    private var missingFrames: [String: Int] = [:]
    private var leftOpponent = OpponentState()
    private var rightOpponent = OpponentState()
    private var events: [GameEvent] = []
    private var nextUnknownEnemyNumber = 1

    func reset(
        ours: ImportedBoardRecord,
        teammate: ImportedBoardRecord
    ) {
        pieces.removeAll()
        trackToPiece.removeAll()
        positionToPiece.removeAll()
        previousTracks.removeAll()
        previousTracksByPosition.removeAll()
        missingFrames.removeAll()
        leftOpponent.reset()
        rightOpponent.reset()
        events.removeAll()
        nextUnknownEnemyNumber = 1

        load(record: ours, side: .ours)
        load(record: teammate, side: .teammate)
    }

    func apply(
        board: BoardSnapshot,
        step: Int?
    ) -> GameStateUpdate {
        guard board.isReliable else {
            return makeUpdate(statusText: "棋盘定位不稳定，暂不更新记牌")
        }

        let currentTracks = Dictionary(uniqueKeysWithValues: board.tracks.map { ($0.id, $0) })
        // 同一帧可能出现新旧轨迹短暂落在同一棋位，保留最后看到的轨迹，避免字典崩溃。
        var currentByPosition: [BoardPoint: BoardTrack] = [:]
        for track in board.tracks {
            if let existing = currentByPosition[track.current],
               existing.lastSeenFrame > track.lastSeenFrame {
                continue
            }
            currentByPosition[track.current] = track
        }

        bindTracks(currentTracks)

        var newEvents: [GameEvent] = []
        for move in board.moves {
            let defenderTrack = previousTracksByPosition[move.to]
            // 同一棋位在同一帧只能有一个棋子。检查“棋位当前归属”而不是
            // 检查轨迹字典是否仍存在，避免被吃掉的棋子在缓存期内被误判为存活。
            let attackerSurvives = currentByPosition[move.to]?.id == move.trackID
            let defenderSurvives = defenderTrack.map {
                currentByPosition[move.to]?.id == $0.id
            } ?? false

            if let defenderTrack, defenderTrack.id != move.trackID {
                if let event = handleCombat(
                    attackerTrackID: move.trackID,
                    defenderTrackID: defenderTrack.id,
                    attackerSurvives: attackerSurvives,
                    defenderSurvives: defenderSurvives
                ) {
                    newEvents.append(event)
                    events.append(event)
                }
            }

            movePiece(trackID: move.trackID, to: move.to)
        }

        for (trackID, _) in previousTracks where currentTracks[trackID] == nil {
            let count = (missingFrames[trackID] ?? 0) + 1
            missingFrames[trackID] = count
            if count >= 6 {
                markTrackDead(trackID)
            }
        }

        for trackID in currentTracks.keys {
            missingFrames[trackID] = 0
            if let pieceID = trackToPiece[trackID],
               var piece = pieces[pieceID],
               let kind = currentTracks[trackID]?.kind {
                piece.kind = kind
                pieces[pieceID] = piece
                revealIfNeeded(pieceID: pieceID)
            }
        }

        previousTracks = currentTracks
        previousTracksByPosition = currentByPosition

        let status: String
        if let event = newEvents.last {
            status = "\(event.side.title)\(event.result.title) · 左敌剩余\(leftOpponent.remainingCount) 右敌剩余\(rightOpponent.remainingCount)"
        } else {
            status = "左敌剩余\(leftOpponent.remainingCount) 右敌剩余\(rightOpponent.remainingCount)"
        }

        return makeUpdate(
            newEvents: newEvents,
            statusText: status
        )
    }

    func confirmedPieces() -> [BoardPoint: PieceKind] {
        var result: [BoardPoint: PieceKind] = [:]
        for piece in pieces.values {
            guard !piece.isDead,
                  let position = piece.position,
                  let kind = piece.kind else {
                continue
            }
            result[position] = kind
        }
        return result
    }

    private func load(record: ImportedBoardRecord, side: BoardSide) {
        for (key, kind) in record.cells {
            guard let position = record.globalPoint(for: key) else { continue }
            let id = "\(record.owner.rawValue)-\(key)"
            pieces[id] = LivePiece(
                id: id,
                side: side,
                kind: kind,
                position: position,
                trackID: nil,
                isRevealed: true,
                isDead: false
            )
            positionToPiece[position] = id
        }
    }

    private func bindTracks(_ tracks: [String: BoardTrack]) {
        for track in tracks.values {
            if let pieceID = trackToPiece[track.id] {
                updatePiece(
                    pieceID: pieceID,
                    track: track
                )
                continue
            }

            if let pieceID = positionToPiece[track.current],
               let piece = pieces[pieceID],
               piece.side == track.side {
                trackToPiece[track.id] = pieceID
                updatePiece(pieceID: pieceID, track: track)
                continue
            }

            let pieceID: String
            if track.side == .leftEnemy || track.side == .rightEnemy || track.side == .center {
                pieceID = "enemy-\(nextUnknownEnemyNumber)"
                nextUnknownEnemyNumber += 1
            } else {
                pieceID = "friendly-\(track.id)"
            }

            pieces[pieceID] = LivePiece(
                id: pieceID,
                side: track.side,
                kind: track.kind,
                position: track.current,
                trackID: track.id,
                isRevealed: track.kind != nil,
                isDead: false
            )
            trackToPiece[track.id] = pieceID
            positionToPiece[track.current] = pieceID
            revealIfNeeded(pieceID: pieceID)
        }
    }

    private func updatePiece(
        pieceID: String,
        track: BoardTrack
    ) {
        guard var piece = pieces[pieceID] else { return }
        if let oldPosition = piece.position, oldPosition != track.current {
            positionToPiece.removeValue(forKey: oldPosition)
        }
        piece.position = track.current
        piece.trackID = track.id
        piece.side = track.side
        if let kind = track.kind {
            piece.kind = kind
        }
        pieces[pieceID] = piece
        positionToPiece[track.current] = pieceID
        revealIfNeeded(pieceID: pieceID)
    }

    private func movePiece(
        trackID: String,
        to position: BoardPoint
    ) {
        guard let pieceID = trackToPiece[trackID],
              var piece = pieces[pieceID] else {
            return
        }
        if let oldPosition = piece.position {
            positionToPiece.removeValue(forKey: oldPosition)
        }
        piece.position = position
        pieces[pieceID] = piece
        positionToPiece[position] = pieceID
    }

    private func markTrackDead(_ trackID: String) {
        guard let pieceID = trackToPiece[trackID],
              let piece = pieces[pieceID],
              piece.trackID == trackID,
              !piece.isDead else {
            return
        }
        markDead(pieceID: pieceID)
    }

    private func markDead(pieceID: String) {
        guard var piece = pieces[pieceID], !piece.isDead else { return }
        piece.isDead = true
        if let position = piece.position {
            positionToPiece.removeValue(forKey: position)
        }
        piece.position = nil
        pieces[pieceID] = piece

        guard piece.side == .leftEnemy || piece.side == .rightEnemy else {
            return
        }

        if let kind = piece.kind {
            var state = opponentState(for: piece.side)
            state.markDead(kind)
            setOpponentState(state, for: piece.side)
        } else {
            var state = opponentState(for: piece.side)
            state.markUnknownDead()
            setOpponentState(state, for: piece.side)
        }
    }

    private func revealIfNeeded(pieceID: String) {
        guard var piece = pieces[pieceID],
              !piece.isDead,
              piece.side == .leftEnemy || piece.side == .rightEnemy,
              let kind = piece.kind,
              !piece.isRevealed else {
            return
        }

        piece.isRevealed = true
        pieces[pieceID] = piece
        var state = opponentState(for: piece.side)
        state.setRevealed(kind, count: state.revealedCount(kind) + 1)
        setOpponentState(state, for: piece.side)
    }

    private func handleCombat(
        attackerTrackID: String,
        defenderTrackID: String,
        attackerSurvives: Bool,
        defenderSurvives: Bool
    ) -> GameEvent? {
        guard let attackerPieceID = trackToPiece[attackerTrackID],
              let defenderPieceID = trackToPiece[defenderTrackID],
              let attacker = pieces[attackerPieceID],
              let defender = pieces[defenderPieceID] else {
            return nil
        }

        let friendly: LivePiece
        let enemy: LivePiece
        let enemyIsAttacker: Bool

        if attacker.side.isFriendly, defender.side.isEnemy {
            friendly = attacker
            enemy = defender
            enemyIsAttacker = false
        } else if defender.side.isFriendly, attacker.side.isEnemy {
            friendly = defender
            enemy = attacker
            enemyIsAttacker = true
        } else {
            if !attackerSurvives { markDead(pieceID: attackerPieceID) }
            if !defenderSurvives { markDead(pieceID: defenderPieceID) }
            return nil
        }

        let enemySurvives = enemyIsAttacker ? attackerSurvives : defenderSurvives
        let friendlySurvives = enemyIsAttacker ? defenderSurvives : attackerSurvives

        if !friendlySurvives {
            markDead(pieceID: friendly.id)
        }
        if !enemySurvives {
            markDead(pieceID: enemy.id)
        }
        if enemySurvives {
            revealIfNeeded(pieceID: enemy.id)
        }

        guard let friendlyKind = friendly.kind,
              enemy.side == .leftEnemy || enemy.side == .rightEnemy else {
            return nil
        }

        let result: GameEvent.Result
        if enemySurvives, !friendlySurvives {
            result = .enemySurvived
        } else if !enemySurvives, !friendlySurvives {
            result = .bothDead
        } else if !enemySurvives, friendlySurvives {
            result = .enemyDeadOursSurvived
        } else {
            result = .enemyDeadUnknown
        }

        return GameEvent(
            side: enemy.side == .leftEnemy ? .left : .right,
            contactID: enemy.id,
            ourPiece: friendlyKind,
            source: enemyIsAttacker ? .enemyMoved : .enemyStationary,
            result: result
        )
    }

    private func opponentState(for side: BoardSide) -> OpponentState {
        side == .leftEnemy ? leftOpponent : rightOpponent
    }

    private func setOpponentState(_ state: OpponentState, for side: BoardSide) {
        if side == .leftEnemy {
            leftOpponent = state
        } else {
            rightOpponent = state
        }
    }

    private func makeUpdate(
        newEvents: [GameEvent] = [],
        statusText: String
    ) -> GameStateUpdate {
        GameStateUpdate(
            leftOpponent: leftOpponent,
            rightOpponent: rightOpponent,
            newEvents: newEvents,
            statusText: statusText
        )
    }
}

private extension BoardSide {
    var isFriendly: Bool {
        self == .ours || self == .teammate
    }

    var isEnemy: Bool {
        self == .leftEnemy || self == .rightEnemy
    }
}
