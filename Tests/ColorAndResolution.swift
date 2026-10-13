import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers
@main struct Regression {
static func rgb(_ image: CGImage,width: Int,height: Int) -> [UInt8] {
 var bytes = [UInt8](repeating:0,count:width*height*4)
 bytes.withUnsafeMutableBytes { p in
 let ctx = CGContext(data:p.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
 ctx.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
 }; return bytes
}
static func main() throws {
 let folder=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
 let space=CGColorSpace(name:CGColorSpace.displayP3)!
 let w=4800,h=1200
 let ctx=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:0,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
 let colors:[[CGFloat]]=[[1,0.2,0.15,1],[0.1,0.85,0.3,1],[0.15,0.3,0.95,1],[0.6,0.35,0.8,1]]
 for (i,color) in colors.enumerated(){ctx.setFillColor(CGColor(colorSpace:space,components:color)!);ctx.fill(CGRect(x:i*1200,y:0,width:1200,height:h))}
 let original=ctx.makeImage()!;let url=folder.appendingPathComponent("display-p3.png")
 let dest=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil)!
 CGImageDestinationAddImage(dest,original,nil);precondition(CGImageDestinationFinalize(dest))
 let result=try compress([url],targetMB:15){_,_ in}
 precondition(result.pages[0].width==w && result.pages[0].height==h,"resolution changed")
 precondition(result.targetMet && result.quality==0.85)
 let source=CGImageSourceCreateWithData(result.pages[0].jpeg as CFData,nil)!
 let jpeg=CGImageSourceCreateImageAtIndex(source,0,nil)!
 precondition(jpeg.colorSpace?.name==CGColorSpace.displayP3,"P3 profile was lost")
 precondition(!result.pages[0].icc.isEmpty)
 let doc=CGPDFDocument(CGDataProvider(data:result.pdf as CFData)!)!,page=doc.page(at:1)!
 let render=CGContext(data:nil,width:800,height:200,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
 render.scaleBy(x:800/2400.0,y:200/600.0);render.drawPDFPage(page)
 let pixels=rgb(render.makeImage()!,width:800,height:200),baseline=rgb(original,width:800,height:200)
 var maxDelta=0
 for x in [100,300,500,700] {let start=(100*800+x)*4;for c in 0..<3 {maxDelta=max(maxDelta,abs(Int(pixels[start+c])-Int(baseline[start+c])))}}
 precondition(maxDelta<=5,"color mismatch: \(maxDelta)")
 let view=NSBitmapImageRep(cgImage:render.makeImage()!);try view.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent("pdf-render.png"))
 try result.pdf.write(to:folder.appendingPathComponent("test.pdf"))
 let tooSmall=try compress([url],targetMB:0.001){_,_ in}
 precondition(!tooSmall.targetMet && tooSmall.pages[0].width==w && tooSmall.quality>=0.30)
 let transparent=CGContext(data:nil,width:320,height:200,bitsPerComponent:8,bytesPerRow:0,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
 let turl=folder.appendingPathComponent("transparent.png"),tdest=CGImageDestinationCreateWithURL(turl as CFURL,UTType.png.identifier as CFString,1,nil)!
 CGImageDestinationAddImage(tdest,transparent,nil);precondition(CGImageDestinationFinalize(tdest))
 let t=try encode(turl,quality:0.98),tsource=CGImageSourceCreateWithData(t.jpeg as CFData,nil)!,ti=CGImageSourceCreateImageAtIndex(tsource,0,nil)!
 let white=rgb(ti,width:320,height:200);precondition(white[0]>=250 && white[1]>=250 && white[2]>=250)
 print("PASS: 4800×1200 intact; Display P3 preserved in JPEG and ICCBased PDF; rendered RGB max delta \(maxDelta)/255; oversized output keeps dimensions and quality floor preserved; transparency white")
}
}
