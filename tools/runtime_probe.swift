import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

enum BoardLayout {
    static let rows = 6
    static let columns = 5
    static let campKeys: Set<String> = [
        "1-1",
        "1-3",
        "2-2",
        "3-1",
        "3-3"
    ]

    static func isCamp(row: Int, col: Int) -> Bool {
        campKeys.contains("\(row)-\(col)")
    }
}

@main
struct RuntimeProbe {
    static func main() async throws {
        guard CommandLine.arguments.count >= 3 else {
            fputs(
                "usage:\n  runtime_probe phase <label> <image> <frames>\n"
                    + "  runtime_probe sequence <image1> <image2> ...\n",
                stderr
            )
            exit(2)
        }

        let mode = CommandLine.arguments[1]
        switch mode {
        case "phase":
            guard CommandLine.arguments.count == 5 else {
                throw ProbeError.invalidArguments
            }
            let label = CommandLine.arguments[2]
            let image = CommandLine.arguments[3]
            let frames = Int(CommandLine.arguments[4]) ?? 25
            try await runPhase(label: label, imagePath: image, frames: frames)
        case "sequence":
            let images = Array(CommandLine.arguments.dropFirst(2))
            try await runSequence(imagePaths: images)
        case "stream":
            let images = Array(CommandLine.arguments.dropFirst(2))
            try await runStream(imagePaths: images)
        default:
            throw ProbeError.invalidArguments
        }
    }

    private static func runPhase(
        label: String,
        imagePath: String,
        frames: Int
    ) async throws {
        let pixelBuffer = try makePixelBuffer(path: imagePath)
        let analyzer = ScreenAnalyzer()
        print("=== phase \(label) image=\(imagePath) frames=\(frames) ===")

        var previousReady = false
        for frame in 0..<frames {
            let snapshot = await analyzer.analyze(pixelBuffer: pixelBuffer)
            let board = snapshot.board
            let shouldPrint = frame == 0
                || frame == frames - 1
                || board?.isSessionReady != previousReady
            if shouldPrint {
                print(snapshotText(frame: frame, snapshot: snapshot))
            }
            previousReady = board?.isSessionReady ?? false
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private static func runSequence(imagePaths: [String]) async throws {
        guard !imagePaths.isEmpty else { throw ProbeError.invalidArguments }
        let analyzer = ScreenAnalyzer()

        print("=== sequence ===")
        var frameIndex = 0
        for imagePath in imagePaths {
            let pixelBuffer = try makePixelBuffer(path: imagePath)
            for _ in 0..<3 {
                let snapshot = await analyzer.analyze(pixelBuffer: pixelBuffer)
                print(snapshotText(frame: frameIndex, snapshot: snapshot))
                frameIndex += 1
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private static func runStream(imagePaths: [String]) async throws {
        guard !imagePaths.isEmpty else { throw ProbeError.invalidArguments }
        let analyzer = ScreenAnalyzer()
        print("=== stream frames=\(imagePaths.count) ===")

        var previousReady = false
        var previousPhase = GameScreenPhase.idle
        for (frameIndex, imagePath) in imagePaths.enumerated() {
            let pixelBuffer = try makePixelBuffer(path: imagePath)
            let snapshot = await analyzer.analyze(pixelBuffer: pixelBuffer)
            let board = snapshot.board
            let ready = board?.isSessionReady ?? false
            let phase = board?.gamePhase ?? .idle
            let shouldPrint = frameIndex == 0
                || frameIndex == imagePaths.count - 1
                || frameIndex % 10 == 0
                || ready != previousReady
                || phase != previousPhase
            if shouldPrint {
                print(snapshotText(frame: frameIndex, snapshot: snapshot))
            }
            previousReady = ready
            previousPhase = phase
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private static func snapshotText(
        frame: Int,
        snapshot: ScreenSnapshot
    ) -> String {
        guard let board = snapshot.board else {
            return "frame=\(frame) phase=\(snapshot.step == nil ? "nil" : "step") board=nil"
        }
        return "frame=\(frame) phase=\(board.gamePhase.rawValue) "
            + "image=\(board.imageWidth)x\(board.imageHeight) "
            + "rect=\(format(board.boardRect)) occupied=\(board.occupiedCount) "
            + "our=\(board.ourOccupiedCount)/25 boardLike=\(board.looksLikeGameBoard) "
            + "ready=\(board.isSessionReady) reliable=\(board.isReliable) "
            + "stable=\(board.stabilityProgress) tracks=\(board.tracks.count) "
            + "moves=\(board.moves.count) step=\(snapshot.step.map(String.init) ?? "nil")"
    }

    private static func format(_ rect: CGRect) -> String {
        String(
            format: "(%.0f,%.0f,%.0f,%.0f)",
            rect.minX,
            rect.minY,
            rect.width,
            rect.height
        )
    }

    private static func makePixelBuffer(path: String) throws -> CVPixelBuffer {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ProbeError.cannotLoadImage(path)
        }

        let maxDimension: CGFloat = 1280
        let scale = min(
            1,
            maxDimension / CGFloat(max(image.width, image.height))
        )
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:]
            ] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw ProbeError.cannotCreatePixelBuffer
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw ProbeError.cannotCreateContext
        }

        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )
        return pixelBuffer
    }
}

private enum ProbeError: LocalizedError {
    case invalidArguments
    case cannotLoadImage(String)
    case cannotCreatePixelBuffer
    case cannotCreateContext

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "invalid arguments"
        case .cannotLoadImage(let path):
            return "cannot load image: \(path)"
        case .cannotCreatePixelBuffer:
            return "cannot create pixel buffer"
        case .cannotCreateContext:
            return "cannot create bitmap context"
        }
    }
}
