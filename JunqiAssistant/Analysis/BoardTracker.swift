import CoreGraphics
import CoreVideo
import Foundation
import Vision

struct RecognizedBoardPiece {
    var kind: PieceKind
    var point: BoardPoint
}

/// 从录屏画面中定位棋盘，并跟踪棋位上棋子的前后帧变化。
final class BoardTracker {
    static let gridSize = 17
    static let ourOpeningPositions: Set<BoardPoint> = {
        var result = Set<BoardPoint>()
        for row in 0..<BoardLayout.rows {
            for col in 0..<BoardLayout.columns
            where !BoardLayout.isCamp(row: row, col: col) {
                result.insert(BoardPoint(row: 11 + row, col: 6 + col))
            }
        }
        return result
    }()

    private var frameIndex = 0
    private var sessionID = 1
    private var nextTrackNumber = 1
    private var isSessionReady = false
    private var isArmed = false
    private var stabilityProgress = 0
    private var unstableFrames = 0
    private var warmupOccupancy: [BoardPoint: Bool] = [:]
    private var stableOccupancy: [BoardPoint: Bool] = [:]
    private var occupancyStreaks: [BoardPoint: Int] = [:]
    private var previousOccupancy: [BoardPoint: Bool] = [:]
    private var previousScores: [BoardPoint: Double] = [:]
    private var cellTracks: [BoardPoint: String] = [:]
    private var tracks: [String: BoardTrack] = [:]

    func process(
        pixelBuffer: CVPixelBuffer,
        boardRect: CGRect,
        usedFallbackRect: Bool,
        phase: GameScreenPhase,
        recognized: [RecognizedBoardPiece]
    ) -> BoardSnapshot {
        frameIndex += 1

        let sampled = sampleBoard(pixelBuffer: pixelBuffer, boardRect: boardRect)
        let classification = makeOccupancy(from: sampled.scores)
        let rawOccupancy = classification.occupancy
        let rawOccupiedCount = rawOccupancy.values.filter { $0 }.count
        let scoreSpread = (sampled.scores.values.max() ?? 0)
            - (sampled.scores.values.min() ?? 0)
        let geometryReliable = (20...180).contains(rawOccupiedCount)
            && scoreSpread > 0.08
        let didStartSession = updateSessionGate(
            occupancy: rawOccupancy,
            geometryReliable: geometryReliable,
            phase: phase
        )
        let ourOccupiedCount = countOurOpeningOccupancy(occupancy: rawOccupancy)
        let boardLike = looksLikeGameBoard(
            occupancy: rawOccupancy,
            ourOccupiedCount: ourOccupiedCount
        )
        let isReliable = geometryReliable && isSessionReady
        let occupancy: [BoardPoint: Bool]
        if isReliable {
            if didStartSession {
                initializeStableOccupancy(rawOccupancy)
                occupancy = rawOccupancy
            } else {
                occupancy = stabilizeOccupancy(rawOccupancy)
            }
        } else {
            occupancy = rawOccupancy
        }
        let occupiedCount = occupancy.values.filter { $0 }.count

        var moves: [BoardMove] = []
        if isReliable {
            if didStartSession {
                // 开局第一帧只建立基准，不产生移动事件。
                previousOccupancy = occupancy
                previousScores = sampled.scores
            }
            moves = updateTracks(
                occupancy: occupancy,
                scores: sampled.scores,
                recognized: recognized
            )
        }

        if isReliable {
            previousOccupancy = occupancy
            previousScores = sampled.scores
        }
        let sideCounts = Dictionary(grouping: tracks.values, by: \.side)
            .mapValues { $0.count }

        return BoardSnapshot(
            frameIndex: frameIndex,
            sessionID: sessionID,
            isSessionReady: isSessionReady,
            stabilityProgress: stabilityProgress,
            gamePhase: phase,
            boardRect: boardRect,
            imageWidth: CVPixelBufferGetWidth(pixelBuffer),
            imageHeight: CVPixelBufferGetHeight(pixelBuffer),
            ourOccupiedCount: ourOccupiedCount,
            looksLikeGameBoard: boardLike,
            isReliable: isReliable,
            occupiedCount: occupiedCount,
            recognizedCount: recognized.count,
            usedFallbackRect: usedFallbackRect,
            scoreMinimum: sampled.scores.values.min() ?? 0,
            scoreMaximum: sampled.scores.values.max() ?? 0,
            occupancyThreshold: classification.threshold,
            sideCounts: sideCounts,
            tracks: tracks.values.sorted { $0.id < $1.id },
            moves: moves
        )
    }

    func reset() {
        frameIndex = 0
        resetSession()
    }

    private func resetSession() {
        sessionID += 1
        nextTrackNumber = 1
        isSessionReady = false
        isArmed = false
        stabilityProgress = 0
        unstableFrames = 0
        warmupOccupancy.removeAll()
        stableOccupancy.removeAll()
        occupancyStreaks.removeAll()
        previousOccupancy.removeAll()
        previousScores.removeAll()
        cellTracks.removeAll()
        tracks.removeAll()
    }

    private func updateSessionGate(
        occupancy: [BoardPoint: Bool],
        geometryReliable: Bool,
        phase: GameScreenPhase
    ) -> Bool {
        if phase == .matching {
            isArmed = false
            if isSessionReady {
                stabilityProgress = 0
                warmupOccupancy.removeAll()
                unstableFrames += 1
                if unstableFrames >= 8 {
                    resetSession()
                }
                return false
            }
            // 匹配文字可能短暂残留。此时仍允许强视觉特征接管，
            // 但必须连续 20 帧确认底部我方开局棋位存在。
        }

        guard geometryReliable else {
            stabilityProgress = 0
            warmupOccupancy.removeAll()
            if isSessionReady {
                unstableFrames += 1
                if unstableFrames >= 12 {
                    resetSession()
                }
            }
            return false
        }

        unstableFrames = 0
        guard !isSessionReady else { return false }

        if phase == .starting {
            guard looksLikeGameBoard(occupancy: occupancy) else { return false }
            isArmed = true
            isSessionReady = true
            warmupOccupancy.removeAll()
            return true
        }
        if phase == .playing {
            guard looksLikeGameBoard(occupancy: occupancy) else {
                stabilityProgress = 0
                warmupOccupancy.removeAll()
                return false
            }
            stabilityProgress = min(2, stabilityProgress + 1)
            guard stabilityProgress >= 2 else { return false }
            isSessionReady = true
            warmupOccupancy.removeAll()
            return true
        }
        if phase == .matched {
            isArmed = true
        }

        guard isArmed else {
            // 文字状态机漏识别时，用底部我方固定棋位做视觉兜底。
            // 必须先确认棋盘确实像正式对局，避免在房间页或菜单页启动。
            guard looksLikeGameBoard(occupancy: occupancy) else {
                stabilityProgress = 0
                warmupOccupancy.removeAll()
                return false
            }
            let current = Set(occupancy.compactMap { $0.value ? $0.key : nil })
            let previous = Set(warmupOccupancy.compactMap { $0.value ? $0.key : nil })
            if previous.isEmpty {
                stabilityProgress = 1
            } else {
                let changed = current.symmetricDifference(previous).count
                let changeRatio = Double(changed) / Double(max(1, current.count))
                stabilityProgress = changeRatio <= 0.05
                    ? min(20, stabilityProgress + 1)
                    : 1
            }
            warmupOccupancy = occupancy
            guard stabilityProgress >= 20 else { return false }
            isSessionReady = true
            warmupOccupancy.removeAll()
            return true
        }

        let current = Set(occupancy.compactMap { $0.value ? $0.key : nil })
        let previous = Set(warmupOccupancy.compactMap { $0.value ? $0.key : nil })
        if previous.isEmpty {
            stabilityProgress = 1
        } else {
            let changed = current.symmetricDifference(previous).count
            let changeRatio = Double(changed) / Double(max(1, current.count))
            stabilityProgress = changeRatio <= 0.08
                ? min(8, stabilityProgress + 1)
                : 1
        }
        warmupOccupancy = occupancy

        guard stabilityProgress >= 8 else { return false }
        isSessionReady = true
        warmupOccupancy.removeAll()
        return true
    }

    private func initializeStableOccupancy(
        _ occupancy: [BoardPoint: Bool]
    ) {
        stableOccupancy = occupancy
        occupancyStreaks = occupancy.mapValues { $0 ? 1 : -1 }
    }

    private func stabilizeOccupancy(
        _ raw: [BoardPoint: Bool]
    ) -> [BoardPoint: Bool] {
        var result = stableOccupancy
        for (point, isRawOccupied) in raw {
            let isStableOccupied = stableOccupancy[point] ?? false
            let currentStreak = occupancyStreaks[point] ?? (isStableOccupied ? 1 : -1)
            let nextStreak = isRawOccupied
                ? max(1, currentStreak + 1)
                : min(-1, currentStreak - 1)
            occupancyStreaks[point] = nextStreak

            if !isStableOccupied, nextStreak >= 3 {
                result[point] = true
            } else if isStableOccupied, nextStreak <= -3 {
                result[point] = false
            } else {
                result[point] = isStableOccupied
            }
        }
        stableOccupancy = result
        return result
    }

    private func looksLikeGameBoard(
        occupancy: [BoardPoint: Bool]
    ) -> Bool {
        let occupiedCount = occupancy.values.filter { $0 }.count
        guard (40...160).contains(occupiedCount) else { return false }

        let ourOccupied = countOurOpeningOccupancy(occupancy: occupancy)
        return ourOccupied >= 12
    }

    private func looksLikeGameBoard(
        occupancy: [BoardPoint: Bool],
        ourOccupiedCount: Int
    ) -> Bool {
        let occupiedCount = occupancy.values.filter { $0 }.count
        return (40...160).contains(occupiedCount)
            && ourOccupiedCount >= 12
    }

    private func countOurOpeningOccupancy(
        occupancy: [BoardPoint: Bool]
    ) -> Int {
        Self.ourOpeningPositions.reduce(0) { count, point in
            count + (occupancy[point] == true ? 1 : 0)
        }
    }

    static func boardPoint(for pixelPoint: CGPoint, in boardRect: CGRect) -> BoardPoint? {
        guard boardRect.width > 0, boardRect.height > 0 else { return nil }

        let normalizedX = (pixelPoint.x - boardRect.minX) / boardRect.width
        let normalizedY = (pixelPoint.y - boardRect.minY) / boardRect.height
        guard normalizedX >= 0, normalizedX <= 1, normalizedY >= 0, normalizedY <= 1 else {
            return nil
        }

        let col = Int((normalizedX * CGFloat(Self.gridSize - 1)).rounded())
        let row = Int((normalizedY * CGFloat(Self.gridSize - 1)).rounded())
        return BoardPoint(
            row: min(max(row, 0), Self.gridSize - 1),
            col: min(max(col, 0), Self.gridSize - 1)
        )
    }

    static func boardPoint(forRelativeX x: CGFloat, y: CGFloat) -> BoardPoint? {
        guard x >= 0, x <= 1, y >= 0, y <= 1 else { return nil }

        let col = Int((x * CGFloat(Self.gridSize - 1)).rounded())
        let row = Int(((1 - y) * CGFloat(Self.gridSize - 1)).rounded())
        return BoardPoint(
            row: min(max(row, 0), Self.gridSize - 1),
            col: min(max(col, 0), Self.gridSize - 1)
        )
    }

    static func side(for point: BoardPoint) -> BoardSide {
        if point.row >= 11, (6...10).contains(point.col) {
            return .ours
        }
        if point.row <= 5, (6...10).contains(point.col) {
            return .teammate
        }
        if point.col <= 5, (6...10).contains(point.row) {
            return .leftEnemy
        }
        if point.col >= 11, (6...10).contains(point.row) {
            return .rightEnemy
        }
        return .center
    }

    private func sampleBoard(
        pixelBuffer: CVPixelBuffer,
        boardRect: CGRect
    ) -> (scores: [BoardPoint: Double], features: [BoardPoint: Double]) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return ([:], [:])
        }

        let sampler = PixelSampler(
            baseAddress: baseAddress.assumingMemoryBound(to: UInt8.self),
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer)
        )

        let spacingX = boardRect.width / CGFloat(Self.gridSize - 1)
        let spacingY = boardRect.height / CGFloat(Self.gridSize - 1)
        let spacing = min(spacingX, spacingY)
        var scores: [BoardPoint: Double] = [:]
        var features: [BoardPoint: Double] = [:]

        for row in 0..<Self.gridSize {
            for col in 0..<Self.gridSize {
                let point = BoardPoint(row: row, col: col)
                let center = CGPoint(
                    x: boardRect.minX + CGFloat(col) * spacingX,
                    y: boardRect.minY + CGFloat(row) * spacingY
                )
                let score = cellScore(center: center, spacing: spacing, sampler: sampler)
                scores[point] = score
                features[point] = score
            }
        }
        return (scores, features)
    }

    private func makeOccupancy(
        from scores: [BoardPoint: Double]
    ) -> (occupancy: [BoardPoint: Bool], threshold: Double) {
        let values = scores.values.sorted()
        guard !values.isEmpty else { return ([:], 1) }

        let minimum = values.first ?? 0
        let maximum = values.last ?? 1
        guard maximum - minimum > 0.0001 else {
            return (scores.mapValues { _ in false }, 1)
        }

        let normalized = scores.mapValues { ($0 - minimum) / (maximum - minimum) }
        let normalizedValues = normalized.values.sorted()
        var threshold = otsuThreshold(normalizedValues)

        // 四国开局四方各 25 枚，共约 100 枚棋子。
        var occupied = normalized.mapValues { $0 > threshold }
        let occupiedCount = occupied.values.filter { $0 }.count
        if occupiedCount < 60 || occupiedCount > 150 {
            let index = min(
                normalizedValues.count - 1,
                max(0, Int(Double(normalizedValues.count) * 0.65))
            )
            threshold = normalizedValues[index] * 0.92
            occupied = normalized.mapValues { $0 > threshold }
        }

        // 使用上一帧做轻微滞回，减少录屏压缩造成的闪烁。
        for point in Set(previousOccupancy.keys).union(occupied.keys) {
            let wasOccupied = previousOccupancy[point] ?? false
            let score = normalized[point] ?? 0
            occupied[point] = score > threshold || (wasOccupied && score > threshold * 0.55)
        }
        return (occupied, threshold)
    }

    private func updateTracks(
        occupancy: [BoardPoint: Bool],
        scores: [BoardPoint: Double],
        recognized: [RecognizedBoardPiece]
    ) -> [BoardMove] {
        let currentOccupied = Set(occupancy.compactMap { $0.value ? $0.key : nil })
        let previousOccupied = Set(previousOccupancy.compactMap { $0.value ? $0.key : nil })
        let removed = previousOccupied.subtracting(currentOccupied)
        let added = currentOccupied.subtracting(previousOccupied)

        var changed = Set<BoardPoint>()
        for point in previousOccupied.intersection(currentOccupied) {
            let oldScore = previousScores[point] ?? 0
            let newScore = scores[point] ?? 0
            if abs(newScore - oldScore) > 0.12 {
                changed.insert(point)
            }
        }

        struct MoveCandidate {
            var oldPoint: BoardPoint
            var target: BoardPoint
            var trackID: String
            var kind: PieceKind?
            var distance: Int
        }

        var candidates: [MoveCandidate] = []
        for oldPoint in removed.sorted(by: pointSort) {
            guard let trackID = cellTracks[oldPoint],
                  let track = tracks[trackID] else {
                continue
            }

            if let target = nearestPoint(to: oldPoint, in: added, maximumDistance: 16) {
                candidates.append(
                    MoveCandidate(
                        oldPoint: oldPoint,
                        target: target,
                        trackID: trackID,
                        kind: track.kind,
                        distance: distance(oldPoint, target)
                    )
                )
            } else if let target = nearestPoint(to: oldPoint, in: changed, maximumDistance: 16) {
                candidates.append(
                    MoveCandidate(
                        oldPoint: oldPoint,
                        target: target,
                        trackID: trackID,
                        kind: track.kind,
                        distance: distance(oldPoint, target)
                    )
                )
            }
        }

        // 一帧只确认一次行棋，选择距离最短的变化作为主事件。
        let bestMove = candidates.min {
            if $0.distance == $1.distance {
                return pointSort($0.oldPoint, $1.oldPoint)
            }
            return $0.distance < $1.distance
        }
        var moves: [BoardMove] = []
        if let bestMove {
            moveTrack(
                trackID: bestMove.trackID,
                from: bestMove.oldPoint,
                to: bestMove.target,
                kind: bestMove.kind
            )
            moves.append(
                BoardMove(
                    trackID: bestMove.trackID,
                    from: bestMove.oldPoint,
                    to: bestMove.target,
                    side: BoardTracker.side(for: bestMove.target),
                    kind: bestMove.kind
                )
            )
        }

        let movedFrom = bestMove?.oldPoint
        let movedTo = bestMove?.target
        for point in removed where point != movedFrom {
            cellTracks.removeValue(forKey: point)
        }
        for point in added.sorted(by: pointSort) where point != movedTo {
            createTrack(at: point)
        }

        for point in currentOccupied where cellTracks[point] == nil {
            createTrack(at: point)
        }

        for recognizedPiece in recognized {
            guard let trackID = cellTracks[recognizedPiece.point],
                  var track = tracks[trackID] else {
                continue
            }
            track.kind = recognizedPiece.kind
            track.lastSeenFrame = frameIndex
            tracks[trackID] = track
        }

        // 静止棋子也必须刷新 lastSeenFrame，否则连续几帧没有移动就会被误删，
        // 随后真实移动会因为轨迹已不存在而丢失。
        for point in currentOccupied {
            guard let trackID = cellTracks[point],
                  var track = tracks[trackID] else {
                continue
            }
            track.current = point
            track.lastSeenFrame = frameIndex
            tracks[trackID] = track
        }

        tracks = tracks.filter { _, track in
            frameIndex - track.lastSeenFrame <= 4
        }

        return moves
    }

    private func createTrack(at point: BoardPoint) {
        let id = "T\(nextTrackNumber)"
        nextTrackNumber += 1
        cellTracks[point] = id
        tracks[id] = BoardTrack(
            id: id,
            current: point,
            history: [point],
            side: Self.side(for: point),
            kind: nil,
            lastSeenFrame: frameIndex
        )
    }

    private func moveTrack(
        trackID: String,
        from oldPoint: BoardPoint,
        to newPoint: BoardPoint,
        kind: PieceKind?
    ) {
        cellTracks.removeValue(forKey: oldPoint)
        cellTracks[newPoint] = trackID

        guard var track = tracks[trackID] else { return }
        track.current = newPoint
        track.history.append(newPoint)
        track.side = Self.side(for: newPoint)
        track.kind = kind
        track.lastSeenFrame = frameIndex
        tracks[trackID] = track
    }

    private func nearestPoint(
        to point: BoardPoint,
        in candidates: Set<BoardPoint>,
        maximumDistance: Int
    ) -> BoardPoint? {
        candidates
            .map { ($0, distance(point, $0)) }
            .filter { $0.1 <= maximumDistance }
            .min { $0.1 < $1.1 }?
            .0
    }

    private func distance(_ lhs: BoardPoint, _ rhs: BoardPoint) -> Int {
        abs(lhs.row - rhs.row) + abs(lhs.col - rhs.col)
    }

    private func pointSort(_ lhs: BoardPoint, _ rhs: BoardPoint) -> Bool {
        lhs.row == rhs.row ? lhs.col < rhs.col : lhs.row < rhs.row
    }

    private func otsuThreshold(_ values: [Double]) -> Double {
        guard values.count > 1 else { return values.first ?? 0 }

        let bins = 64
        var histogram = Array(repeating: 0, count: bins)
        for value in values {
            let index = min(bins - 1, max(0, Int(value * Double(bins - 1))))
            histogram[index] += 1
        }

        let total = values.count
        var sum = 0.0
        for index in 0..<bins {
            sum += Double(index) * Double(histogram[index])
        }

        var backgroundWeight = 0
        var backgroundSum = 0.0
        var bestVariance = 0.0
        var bestThreshold = 0.5

        for index in 0..<bins {
            backgroundWeight += histogram[index]
            if backgroundWeight == 0 { continue }

            let foregroundWeight = total - backgroundWeight
            if foregroundWeight == 0 { break }

            backgroundSum += Double(index) * Double(histogram[index])
            let backgroundMean = backgroundSum / Double(backgroundWeight)
            let foregroundMean = (sum - backgroundSum) / Double(foregroundWeight)
            let between = Double(backgroundWeight * foregroundWeight)
                * (backgroundMean - foregroundMean) * (backgroundMean - foregroundMean)

            if between > bestVariance {
                bestVariance = between
                bestThreshold = Double(index) / Double(bins - 1)
            }
        }
        return bestThreshold
    }

    private func cellScore(center: CGPoint, spacing: CGFloat, sampler: PixelSampler) -> Double {
        let innerRadius = spacing * 0.26
        let outerRadius = spacing * 0.44

        var inner: [PixelSampler.RGB] = []
        var ring: [PixelSampler.RGB] = []

        let offsets = [-2, -1, 0, 1, 2]
        for yOffset in offsets {
            for xOffset in offsets {
                let x = center.x + CGFloat(xOffset) * innerRadius / 2
                let y = center.y + CGFloat(yOffset) * innerRadius / 2
                inner.append(sampler.rgb(x: x, y: y))
            }
        }

        for index in -3...3 {
            let offset = CGFloat(index) * outerRadius / 3
            ring.append(sampler.rgb(x: center.x + offset, y: center.y - outerRadius))
            ring.append(sampler.rgb(x: center.x + offset, y: center.y + outerRadius))
            ring.append(sampler.rgb(x: center.x - outerRadius, y: center.y + offset))
            ring.append(sampler.rgb(x: center.x + outerRadius, y: center.y + offset))
        }

        guard !inner.isEmpty, !ring.isEmpty else { return 0 }

        let innerMean = averageColor(inner)
        let ringMean = averageColor(ring)
        let colorDifference = (
            abs(innerMean.red - ringMean.red)
                + abs(innerMean.green - ringMean.green)
                + abs(innerMean.blue - ringMean.blue)
        ) / (3 * 255)

        let luminances = inner.map { $0.luminance }
        let mean = luminances.reduce(0, +) / Double(luminances.count)
        let variance = luminances.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
            / Double(luminances.count)
        let contrast = min(1, sqrt(variance) / 72)

        var edge = 0.0
        var edgeCount = 0
        for row in 0..<5 {
            for col in 0..<4 {
                let left = inner[row * 5 + col].luminance
                let right = inner[row * 5 + col + 1].luminance
                edge += abs(left - right)
                edgeCount += 1
            }
        }
        let edgeScore = edgeCount > 0 ? min(1, edge / Double(edgeCount) / 80) : 0

        return colorDifference * 0.52 + contrast * 0.30 + edgeScore * 0.18
    }

    private func averageColor(_ colors: [PixelSampler.RGB]) -> PixelSampler.RGB {
        let count = Double(colors.count)
        return PixelSampler.RGB(
            red: colors.reduce(0) { $0 + Double($1.red) } / count,
            green: colors.reduce(0) { $0 + Double($1.green) } / count,
            blue: colors.reduce(0) { $0 + Double($1.blue) } / count
        )
    }
}

struct BoardDetection {
    var rect: CGRect
    var usedFallback: Bool
}

enum BoardDetector {
    static func detect(in pixelBuffer: CVPixelBuffer) -> BoardDetection {
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))

        // 四国军棋实战界面是横屏，棋盘固定在画面中央并几乎铺满高度。
        // 直接使用归一化固定区域，避免 Vision 误把画中画或其他矩形当成棋盘。
        if width > height * 1.2 {
            return BoardDetection(
                rect: fallbackRect(for: pixelBuffer),
                usedFallback: true
            )
        }

        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 20
        request.minimumConfidence = 0.35
        request.minimumAspectRatio = 0.78
        request.maximumAspectRatio = 1.22
        request.minimumSize = 0.25
        request.quadratureTolerance = 25

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return BoardDetection(rect: fallbackRect(for: pixelBuffer), usedFallback: true)
        }

        let candidates = (request.results ?? []).compactMap { observation -> CGRect? in
            let box = observation.boundingBox
            let rect = CGRect(
                x: box.minX * width,
                y: (1 - box.maxY) * height,
                width: box.width * width,
                height: box.height * height
            )
            guard rect.width > width * 0.25, rect.height > height * 0.18 else { return nil }
            return rect
        }

        if let best = candidates.max(by: { lhs, rhs in
            lhs.width * lhs.height < rhs.width * rhs.height
        }) {
            return BoardDetection(rect: best, usedFallback: false)
        }
        return BoardDetection(rect: fallbackRect(for: pixelBuffer), usedFallback: true)
    }

    private static func fallbackRect(for pixelBuffer: CVPixelBuffer) -> CGRect {
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))

        if height >= width {
            let side = min(width * 0.94, height * 0.78)
            return CGRect(
                x: (width - side) / 2,
                y: height * 0.48 - side / 2,
                width: side,
                height: side
            )
        }

        let side = min(height * 0.94, width * 0.78)
        return CGRect(
            x: width / 2 - side / 2,
            y: (height - side) / 2,
            width: side,
            height: side
        )
    }
}

private struct PixelSampler {
    struct RGB {
        var red: Double
        var green: Double
        var blue: Double

        var luminance: Double {
            red * 0.2126 + green * 0.7152 + blue * 0.0722
        }
    }

    let baseAddress: UnsafePointer<UInt8>
    let width: Int
    let height: Int
    let bytesPerRow: Int

    func rgb(x: CGFloat, y: CGFloat) -> RGB {
        let pixelX = min(max(Int(x.rounded()), 0), max(0, width - 1))
        let pixelY = min(max(Int(y.rounded()), 0), max(0, height - 1))
        let offset = pixelY * bytesPerRow + pixelX * 4

        // 上游 JPEG 解码统一输出 BGRA。
        let blue = Double(baseAddress[offset])
        let green = Double(baseAddress[offset + 1])
        let red = Double(baseAddress[offset + 2])
        return RGB(red: red, green: green, blue: blue)
    }
}
