import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

func expandImageInputs(_ inputs: [URL]) -> [URL] {
    let extensions: Set<String> = ["png","jpg","jpeg","tif","tiff","heic","heif","webp"]
    var files: [URL] = []
    for input in inputs {
        let values = try? input.resourceValues(forKeys:[.isDirectoryKey,.isRegularFileKey,.isSymbolicLinkKey])
        if values?.isDirectory == true {
            if let scan = FileManager.default.enumerator(at:input,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey],options:[.skipsHiddenFiles,.skipsPackageDescendants]) {
                for case let url as URL in scan {
                    let properties = try? url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
                    if properties?.isRegularFile == true && properties?.isSymbolicLink != true && extensions.contains(url.pathExtension.lowercased()) { files.append(url) }
                }
            }
        } else if values?.isRegularFile == true && extensions.contains(input.pathExtension.lowercased()) { files.append(input) }
    }
    var seen: Set<URL> = []
    return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }.filter { seen.insert($0.standardizedFileURL).inserted }
}

struct PageItem: Identifiable {
    let id = UUID()
    let url: URL
    let width: Int
    let height: Int
    let bytes: Int
    let thumbnail: NSImage
    static func load(_ url: URL) throws -> PageItem {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int,
              let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:240,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary)
        else { throw PressError.message("无法读取图片：\(url.lastPathComponent)") }
        let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        return PageItem(url:url,width:w,height:h,bytes:size,thumbnail:NSImage(cgImage:thumb,size:.zero))
    }
}
enum PressError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
struct EncodedPage { let jpeg: Data; let width: Int; let height: Int; let icc: Data }
struct PressResult {
    let pdf: Data; let pages: [EncodedPage]; let quality: Double; let targetMet: Bool
}
func sizeText(_ bytes: Int) -> String { String(format:"%.2f MB",Double(bytes)/1_000_000) }

// Each JPEG is embedded unchanged with its own ICC profile, including Display P3.
func makePDF(_ pages: [EncodedPage]) -> Data {
    var data = Data("%PDF-1.4\n%âãÏÓ\n".utf8)
    var offsets = [0]
    func append(_ s: String) { data.append(Data(s.utf8)) }
    func object(_ n: Int, _ body: Data) {
        offsets.append(data.count); append("\(n) 0 obj\n"); data.append(body); append("\nendobj\n")
    }
    func stream(_ header: String, _ bytes: Data) -> Data {
        var result = Data("<< \(header) /Length \(bytes.count) >>\nstream\n".utf8)
        result.append(bytes); result.append(Data("\nendstream".utf8)); return result
    }
    object(1,Data("<< /Type /Catalog /Pages 2 0 R >>".utf8))
    let kids = pages.indices.map { "\(3+$0*4) 0 R" }.joined(separator:" ")
    object(2,Data("<< /Type /Pages /Count \(pages.count) /Kids [\(kids)] >>".utf8))
    for (i,page) in pages.enumerated() {
        let n = 3+i*4
        let w = Double(page.width)*0.5, h = Double(page.height)*0.5
        object(n,Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(w) \(h)] /Resources << /XObject << /Im0 \(n+1) 0 R >> >> /Contents \(n+2) 0 R >>".utf8))
        object(n+1,stream("/Type /XObject /Subtype /Image /Width \(page.width) /Height \(page.height) /ColorSpace [/ICCBased \(n+3) 0 R] /BitsPerComponent 8 /Filter /DCTDecode",page.jpeg))
        let commands = "q\n\(w) 0 0 \(h) 0 0 cm\n/Im0 Do\nQ\n"
        object(n+2,stream("",Data(commands.utf8)))
        object(n+3,stream("/N 3 /Alternate /DeviceRGB",page.icc))
    }
    let start = data.count
    append("xref\n0 \(offsets.count)\n0000000000 65535 f \n")
    for offset in offsets.dropFirst() { append(String(format:"%010d 00000 n \n",offset)) }
    append("trailer\n<< /Size \(offsets.count) /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF\n")
    return data
}
func encode(_ url: URL, quality: Double) throws -> EncodedPage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL,nil),
          let image = CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCache:false] as CFDictionary)
    else { throw PressError.message("图片读取失败：\(url.lastPathComponent)") }
    let props = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any]
    let orientation = (props?[kCGImagePropertyOrientation] as? Int) ?? 1
    // Preserve orientation at native resolution; never generate a reduced thumbnail.
    let rotate = orientation >= 5 && orientation <= 8
    let width = rotate ? image.height : image.width
    let height = rotate ? image.width : image.height
    let originalSpace = image.colorSpace
    let space: CGColorSpace
    if let originalSpace, originalSpace.model == .rgb, originalSpace.copyICCData() != nil {
        space = originalSpace
    } else { space = CGColorSpace(name:CGColorSpace.sRGB)! }
    guard let profile = space.copyICCData() else { throw PressError.message("无法读取色彩配置：\(url.lastPathComponent)") }
    guard let ctx = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:space,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)
    else { throw PressError.message("原尺寸图片处理内存不足：\(url.lastPathComponent)") }
    ctx.setFillColor(CGColor(colorSpace:space,components:[1,1,1,1])!); ctx.fill(CGRect(x:0,y:0,width:width,height:height))
    // EXIF orientation transforms into an upright image without resizing.
    switch orientation {
    case 2: ctx.translateBy(x:CGFloat(width),y:0); ctx.scaleBy(x:-1,y:1)
    case 3: ctx.translateBy(x:CGFloat(width),y:CGFloat(height)); ctx.rotate(by:.pi)
    case 4: ctx.translateBy(x:0,y:CGFloat(height)); ctx.scaleBy(x:1,y:-1)
    case 5: ctx.concatenate(CGAffineTransform(a:0,b:-1,c:-1,d:0,tx:CGFloat(width),ty:CGFloat(height)))
    case 6: ctx.translateBy(x:0,y:CGFloat(height)); ctx.rotate(by:-.pi/2)
    case 7: ctx.concatenate(CGAffineTransform(a:0,b:1,c:1,d:0,tx:0,ty:0))
    case 8: ctx.translateBy(x:CGFloat(width),y:0); ctx.rotate(by:.pi/2)
    default: break
    }
    ctx.interpolationQuality = .none
    ctx.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
    let out = NSMutableData()
    guard let flat = ctx.makeImage(),let destination = CGImageDestinationCreateWithData(out,UTType.jpeg.identifier as CFString,1,nil) else { throw PressError.message("无法编码图片") }
    CGImageDestinationAddImage(destination,flat,[kCGImageDestinationLossyCompressionQuality:quality,kCGImagePropertyOrientation:1] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw PressError.message("图片编码失败") }
    // Profile in the PDF must match the profile actually attached to the encoded JPEG.
    guard let encoded = CGImageSourceCreateWithData(out,nil),let decoded = CGImageSourceCreateImageAtIndex(encoded,0,nil),
          let jpegICC = decoded.colorSpace?.copyICCData() else { throw PressError.message("编码后缺少色彩配置，已停止导出以避免偏色") }
    _ = profile
    return EncodedPage(jpeg:out as Data,width:width,height:height,icc:jpegICC as Data)
}
func compress(_ urls: [URL], targetMB: Double, minimumQuality: Double = 0.30, progress: @escaping (Double,String)->Void, cancelled: ()->Bool = {false}) throws -> PressResult {
    guard !urls.isEmpty else { throw PressError.message("请先添加图片") }
    guard targetMB.isFinite,targetMB > 0,minimumQuality >= 0.1,minimumQuality <= 0.85 else { throw PressError.message("无效的压缩设置") }
    let limit = Int(targetMB*1_000_000), budget = Int(Double(limit)*0.99)
    var round = 0
    func attempt(_ quality: Double) throws -> PressResult {
        round += 1
        var pages: [EncodedPage] = []
        for (index,url) in urls.enumerated() {
            if cancelled() { throw PressError.message("已取消处理") }
            pages.append(try autoreleasepool { try encode(url,quality:quality) })
            progress(min(0.98,Double((round-1)*urls.count+index+1)/Double(8*urls.count)),"保持原尺寸 · 第 \(round) 轮 · \(index+1)/\(urls.count) 页")
        }
        let pdf = makePDF(pages)
        return PressResult(pdf:pdf,pages:pages,quality:quality,targetMet:pdf.count <= limit)
    }
    let high = try attempt(0.85)
    if high.pdf.count <= budget { progress(1,"处理完成");return high }
    let low = try attempt(minimumQuality)
    if !low.targetMet { progress(1,"当前档位无法满足体积目标，已保留原尺寸");return low }
    var best = low, left = minimumQuality, right = 0.85
    // Search for the clearest encoding that fits the measured PDF budget.
    for _ in 0..<6 {
        let midpoint = (left+right)/2
        let candidate = try attempt(midpoint)
        if candidate.pdf.count <= budget { best = candidate; left = midpoint }
        else { right = midpoint }
    }
    progress(1,"处理完成")
    return best
}
