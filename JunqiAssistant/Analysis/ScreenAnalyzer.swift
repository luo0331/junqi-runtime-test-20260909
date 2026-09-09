import Foundation
import Vision
import CoreVideo

final class ScreenAnalyzer {
    private let queue = DispatchQueue(label: "com.junqi.assistant.vision", qos: .userInitiated)
    private let ocrQueue = DispatchQueue(label: "com.junqi.assistant.ocr", qos: .userInitiated)
    private let boardTracker = BoardTracker()
    private var lastStep: Int?
    private var lastOCRTime = Date.distantPast
    private var lastBoardDetectionTime = Date.distantPast
    private var isOCRRunning = false
    private var ocrGeneration = 0
    private var cachedBoardDetection: BoardDetection?
    private var cachedStep: Int?
    private var cachedPieces: [DetectedPiece] = []
    private var cachedRecognizedPieces: [RecognizedBoardPiece] = []
    private var cachedPhase: GameScreenPhase = .idle
    private var cachedRawText = ""
    private var lastOCRErrorText: String?

    func reset() {
        queue.async {
            self.boardTracker.reset()
            self.lastStep = nil
            self.lastOCRTime = .distantPast
            self.lastBoardDetectionTime = .distantPast
            self.isOCRRunning = false
            self.ocrGeneration += 1
            self.cachedBoardDetection = nil
            self.cachedStep = nil
            self.cachedPieces.removeAll()
            self.cachedRecognizedPieces.removeAll()
            self.cachedPhase = .idle
            self.cachedRawText = ""
            self.lastOCRErrorText = nil
        }
    }

    func analyze(pixelBuffer: CVPixelBuffer) async -> ScreenSnapshot {
        await withCheckedContinuation { continuation in
            queue.async {
                let snapshot = self.recognize(pixelBuffer: pixelBuffer)
                continuation.resume(returning: snapshot)
            }
        }
    }

    private func recognize(pixelBuffer: CVPixelBuffer) -> ScreenSnapshot {
        let now = Date()
        let detection: BoardDetection
        if let cachedBoardDetection,
           now.timeIntervalSince(lastBoardDetectionTime) < 1.0 {
            detection = cachedBoardDetection
        } else {
            detection = BoardDetector.detect(in: pixelBuffer)
            cachedBoardDetection = detection
            lastBoardDetectionTime = now
        }
        let board = analyzeBoard(
            pixelBuffer: pixelBuffer,
            detection: detection,
            recognized: cachedRecognizedPieces
        )

        scheduleOCRIfNeeded(
            pixelBuffer: pixelBuffer,
            boardRect: detection.rect,
            now: now
        )

        let rawText = lastOCRErrorText ?? cachedRawText
        return ScreenSnapshot(
            step: cachedStep,
            rawText: rawText,
            pieces: cachedPieces,
            board: board,
            capturedAt: Date()
        )
    }

    private struct OCRResult {
        var step: Int?
        var pieces: [DetectedPiece]
        var rawText: String
        var recognizedPieces: [RecognizedBoardPiece]
        var phase: GameScreenPhase
        var errorText: String?
    }

    private func scheduleOCRIfNeeded(
        pixelBuffer: CVPixelBuffer,
        boardRect: CGRect,
        now: Date
    ) {
        let isDue = now.timeIntervalSince(lastOCRTime) >= 1.0
            || cachedRawText.isEmpty
        guard isDue, !isOCRRunning else { return }

        isOCRRunning = true
        lastOCRTime = now
        let generation = ocrGeneration
        let buffer = pixelBuffer

        ocrQueue.async { [weak self] in
            guard let self else { return }
            let result = self.performOCR(
                pixelBuffer: buffer,
                boardRect: boardRect
            )
            self.queue.async {
                guard self.ocrGeneration == generation else { return }
                self.applyOCRResult(result)
                self.isOCRRunning = false
            }
        }
    }

    private func performOCR(
        pixelBuffer: CVPixelBuffer,
        boardRect: CGRect
    ) -> OCRResult {
        // 全屏 OCR 只用于读取步数，不把微信界面或画中画文字混入棋子结果。
        let stepRequest = VNRecognizeTextRequest()
        stepRequest.recognitionLevel = .fast
        stepRequest.recognitionLanguages = ["zh-Hans", "en-US"]
        stepRequest.usesLanguageCorrection = false
        stepRequest.minimumTextHeight = 0.012

        // 棋子 OCR 只扫描棋盘区域，减少系统文字和画中画造成的自我识别。
        let boardRequest = VNRecognizeTextRequest()
        boardRequest.recognitionLevel = .accurate
        boardRequest.recognitionLanguages = ["zh-Hans", "en-US"]
        boardRequest.usesLanguageCorrection = false
        boardRequest.minimumTextHeight = 0.005
        boardRequest.regionOfInterest = visionRegion(
            for: boardRect,
            pixelBuffer: pixelBuffer
        )

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([stepRequest, boardRequest])
        } catch {
            return OCRResult(
                step: nil,
                pieces: [],
                rawText: "OCR失败：\(error.localizedDescription)",
                recognizedPieces: [],
                phase: .idle,
                errorText: "OCR失败：\(error.localizedDescription)"
            )
        }

        let stepObservations = (stepRequest.results as? [VNRecognizedTextObservation]) ?? []
        let boardObservations = (boardRequest.results as? [VNRecognizedTextObservation]) ?? []
        let stepText = stepObservations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
        let step = parseStep(from: stepText)
        let phase = parsePhase(from: stepText, step: step)

        var pieces: [DetectedPiece] = []
        for observation in boardObservations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            let tokens = text
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
            let matchTexts = tokens.isEmpty ? [text] : tokens

            for matchText in matchTexts {
                for kind in PieceKind.match(matchText) {
                    pieces.append(
                        DetectedPiece(
                            kind: kind,
                            text: matchText,
                            normalizedRect: observation.boundingBox
                        )
                    )
                }
            }
        }

        let recognizedPieces = pieces.compactMap { piece -> RecognizedBoardPiece? in
            guard let point = BoardTracker.boardPoint(
                forRelativeX: piece.normalizedRect.midX,
                y: piece.normalizedRect.midY
            ) else {
                return nil
            }
            return RecognizedBoardPiece(kind: piece.kind, point: point)
        }
        return OCRResult(
            step: step,
            pieces: pieces,
            rawText: makeDisplayText(step: step, pieces: pieces),
            recognizedPieces: recognizedPieces,
            phase: phase,
            errorText: nil
        )
    }

    private func applyOCRResult(_ result: OCRResult) {
        if let step = result.step {
            if step <= 1, lastStep != step {
                boardTracker.reset()
            }
            lastStep = step
        }

        cachedStep = result.step
        cachedPieces = result.pieces
        cachedRawText = result.rawText
        cachedRecognizedPieces = result.recognizedPieces
        cachedPhase = result.phase
        lastOCRErrorText = result.errorText
    }

    private func analyzeBoard(
        pixelBuffer: CVPixelBuffer,
        detection: BoardDetection,
        recognized: [RecognizedBoardPiece]
    ) -> BoardSnapshot? {
        // 步数只用于显示和重置，不能阻塞棋盘跟踪。
        // 实战中步数文字经常被动画或画中画遮挡，棋盘变化仍然必须继续分析。
        return boardTracker.process(
            pixelBuffer: pixelBuffer,
            boardRect: detection.rect,
            usedFallbackRect: detection.usedFallback,
            phase: cachedPhase,
            recognized: recognized
        )
    }

    private func visionRegion(
        for rect: CGRect,
        pixelBuffer: CVPixelBuffer
    ) -> CGRect {
        let width = max(1, CGFloat(CVPixelBufferGetWidth(pixelBuffer)))
        let height = max(1, CGFloat(CVPixelBufferGetHeight(pixelBuffer)))
        let region = CGRect(
            x: rect.minX / width,
            y: 1 - rect.maxY / height,
            width: rect.width / width,
            height: rect.height / height
        )
        return region
            .insetBy(dx: -0.01, dy: -0.01)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private func makeDisplayText(step: Int?, pieces: [DetectedPiece]) -> String {
        var lines: [String] = []
        if let step {
            lines.append("第\(step)步")
        }

        let uniqueNames = Array(Set(pieces.map(\.kind.name))).sorted()
        if !uniqueNames.isEmpty {
            lines.append("棋盘识别：" + uniqueNames.joined(separator: "、"))
        } else {
            lines.append("棋盘内暂未识别到棋子文字")
        }
        return lines.joined(separator: "\n")
    }

    private func parseStep(from text: String) -> Int? {
        let compact = text.replacingOccurrences(of: " ", with: "")
        let patterns = [
            "第(\\d+)步",
            "第(\\d+)",
            "(\\d+)步"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(compact.startIndex..<compact.endIndex, in: compact)
            guard let match = regex.firstMatch(in: compact, range: range),
                  match.numberOfRanges > 1,
                  let stepRange = Range(match.range(at: 1), in: compact) else {
                continue
            }
            if let step = Int(compact[stepRange]) {
                return step
            }
        }
        return nil
    }

    private func parsePhase(
        from text: String,
        step: Int?
    ) -> GameScreenPhase {
        let compact = text
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "：", with: "")
            .replacingOccurrences(of: ":", with: "")

        if compact.contains("正在匹配")
            || compact.contains("匹配小伙伴")
            || compact.contains("匹配中") {
            return .matching
        }
        if compact.contains("对局开始")
            || compact.contains("开始对局")
            || compact.contains("对局开") {
            return .starting
        }
        if compact.contains("配对成功")
            || compact.contains("对战") {
            return .matched
        }
        if step != nil {
            return .playing
        }
        return .idle
    }
}

