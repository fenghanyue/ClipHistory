import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageStoreError: Error {
    case undecodable
    case encodeFailed
}

/// 图片文件的存取：原图统一存成 PNG（images/<哈希>.png），另存一份缩略图（thumbs/<哈希>.png）供列表显示
public final class ImageStore {
    public let imagesDirectory: URL
    public let thumbnailsDirectory: URL
    private let thumbnailMaxPixels: Int

    public init(rootDirectory: URL, thumbnailMaxPixels: Int = Config.thumbnailMaxPixels) throws {
        imagesDirectory = rootDirectory.appendingPathComponent("images", isDirectory: true)
        thumbnailsDirectory = rootDirectory.appendingPathComponent("thumbs", isDirectory: true)
        self.thumbnailMaxPixels = thumbnailMaxPixels
        try FileManager.default.createPrivateDirectory(at: imagesDirectory)
        try FileManager.default.createPrivateDirectory(at: thumbnailsDirectory)
    }

    /// 读取图片像素尺寸（只读文件头，不整图解码）；无法识别时返回 nil
    public static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    public func imageURL(hash: String) -> URL {
        imagesDirectory.appendingPathComponent("\(hash).png")
    }

    public func thumbnailURL(hash: String) -> URL {
        thumbnailsDirectory.appendingPathComponent("\(hash).png")
    }

    /// 保存原图（PNG 原样写入，TIFF 转成 PNG）和缩略图，返回原图文件大小（字节）
    public func save(data: Data, format: ImageFormat, hash: String) throws -> Int {
        let pngData = format == .png ? data : try Self.encodePNG(Self.decodeImage(data))
        try pngData.write(to: imageURL(hash: hash), options: .atomic)
        try writeThumbnail(from: pngData, hash: hash)
        return pngData.count
    }

    /// 用原图重新生成缩略图（启动校验发现缩略图丢失时用）
    public func regenerateThumbnail(hash: String) throws {
        try writeThumbnail(from: Data(contentsOf: imageURL(hash: hash)), hash: hash)
    }

    /// 删除原图和缩略图（文件不存在也不报错）
    public func delete(hash: String) {
        try? FileManager.default.removeItem(at: imageURL(hash: hash))
        try? FileManager.default.removeItem(at: thumbnailURL(hash: hash))
    }

    /// 两个目录下所有 .png 文件
    public func storedFiles() -> [URL] {
        [imagesDirectory, thumbnailsDirectory].flatMap { directory in
            ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "png" }
        }
    }

    private func writeThumbnail(from data: Data, hash: String) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ImageStoreError.undecodable
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixels,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageStoreError.undecodable
        }
        try Self.encodePNG(thumbnail).write(to: thumbnailURL(hash: hash), options: .atomic)
    }

    private static func decodeImage(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageStoreError.undecodable
        }
        return image
    }

    private static func encodePNG(_ image: CGImage) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw ImageStoreError.encodeFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageStoreError.encodeFailed
        }
        return output as Data
    }
}
