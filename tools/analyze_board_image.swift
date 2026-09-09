import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

@main
struct AnalyzeBoardImage {
    static func main() throws {
        guard CommandLine.arguments.count >= 2 else {
            fputs("usage: analyze_board_image.swift image.jpg\n", stderr)
            exit(2)
        }

        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let sourceImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AnalysisError.cannotLoadImage
        }

        let maxDimension: CGFloat = 1280
        let scale = min(
            1,
            maxDimension / CGFloat(max(sourceImage.width, sourceImage.height))
        )
        let width = max(1, Int(CGFloat(sourceImage.width) * scale))
        let height = max(1, Int(CGFloat(sourceImage.height) * scale))

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
            throw AnalysisError.cannotCreatePixelBuffer
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
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
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            throw AnalysisError.cannotCreateContext
        }
        context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        print("image=\(width)x\(height)")
        let detection = BoardDetector.detect(in: pixelBuffer)
        print(
            "detection=\(detection.rect) fallback=\(detection.usedFallback)"
        )

        let tracker = BoardTracker()
        let snapshot = tracker.process(
            pixelBuffer: pixelBuffer,
            boardRect: detection.rect,
            usedFallbackRect: detection.usedFallback,
            phase: .playing,
            recognized: []
        )
        print("reliable=\(snapshot.isReliable)")
        print("occupied=\(snapshot.occupiedCount)")
        print("scoreMin=\(snapshot.scoreMinimum)")
        print("scoreMax=\(snapshot.scoreMaximum)")
        print("threshold=\(snapshot.occupancyThreshold)")
    }
}

private enum AnalysisError: Error {
    case cannotLoadImage
    case cannotCreatePixelBuffer
    case cannotCreateContext
}
