import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

@MainActor final class Store: ObservableObject {
    @Published var items: [PageItem] = []
    @Published var selected: UUID?
    @Published var target = UserDefaults.standard.object(forKey:"targetMB") as? Double ?? 15.0 { didSet { UserDefaults.standard.set(target,forKey:"targetMB") } }
    @Published var minimumQuality = UserDefaults.standard.object(forKey:"qualityFloorV13") as? Double ?? 0.30 { didSet { UserDefaults.standard.set(minimumQuality,forKey:"qualityFloorV13") } }
    @Published var busy = false
    @Published var progress = 0.0
    @Published var status = "所有处理均在本机完成"
    @Published var result: PressResult?
    @Published var error: String?
    @Published var processedPreview = false
    @Published var zoom = 1.0
    var selectedIndex: Int? { items.firstIndex { $0.id == selected } }
    var originalSize: Int { items.reduce(0) { $0+$1.bytes } }
    func invalidate() { result = nil; processedPreview = false }
    func add(_ urls: [URL]) {
        guard !busy else { return }
        var failures: [String] = []
        let expanded = expandImageInputs(urls)
        if expanded.isEmpty { error = "所选文件夹中未找到支持的图片，或没有读取权限。"; return }
        for url in expanded {
            if items.contains(where: { $0.url == url }) { continue }
            do { items.append(try PageItem.load(url)) } catch { failures.append(url.lastPathComponent) }
        }
        if selected == nil { selected = items.first?.id }; invalidate()
        if !failures.isEmpty { error = "这些文件无法作为图片导入：\n"+failures.joined(separator:"\n") }
    }
    func choose() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png,.jpeg,.tiff,.heic,.webP]; panel.allowsMultipleSelection = true; panel.canChooseDirectories = true
        panel.message = "选择作品集图片或整个文件夹"
        if panel.runModal() == .OK { add(panel.urls) }
    }
    func move(_ delta: Int) {
        guard let i = selectedIndex,items.indices.contains(i+delta),!busy else { return }
        items.swapAt(i,i+delta); invalidate()
    }
    func remove() {
        guard let i = selectedIndex,!busy else { return }
        items.remove(at:i); selected = items.isEmpty ? nil : items[min(i,items.count-1)].id; invalidate()
    }
    func build() {
        guard !busy,!items.isEmpty else { return }
        busy = true; result = nil; progress = 0; status = "准备处理…"
        let urls = items.map(\.url), mb = target, floor = minimumQuality
        DispatchQueue.global(qos:.userInitiated).async {
            do {
                let output = try compress(urls,targetMB:mb,minimumQuality:floor) { p,s in
                    DispatchQueue.main.async { self.progress = p; self.status = s }
                }
                DispatchQueue.main.async { self.result = output; self.busy = false; self.processedPreview = true; self.status = output.targetMet ? "已达标 · \(sizeText(output.pdf.count))" : "超过目标 · 已保留原尺寸，请提高体积上限或减少页数" }
            } catch {
                DispatchQueue.main.async { self.busy = false; self.error = error.localizedDescription; self.status = "处理未完成" }
            }
        }
    }
    func save() {
        guard let result else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]; panel.nameFieldStringValue = "作品集.pdf"
        if panel.runModal() == .OK, let url = panel.url {
            do { try result.pdf.write(to:url,options:.atomic); status = "已导出：\(url.lastPathComponent)"; NSWorkspace.shared.activateFileViewerSelecting([url]) } catch { self.error = error.localizedDescription }
        }
    }
    func saveImages() {
        guard let result else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.prompt = "导出到此文件夹"
        guard panel.runModal() == .OK,let parent = panel.url else { return }
        do {
            let folder = parent.appendingPathComponent("作品集压缩图片-"+UUID().uuidString.prefix(8))
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            for (i,page) in result.pages.enumerated() { try page.jpeg.write(to:folder.appendingPathComponent(String(format:"%03d.jpg",i+1)),options:.atomic) }
            NSWorkspace.shared.activateFileViewerSelecting([folder]); status = "已导出 \(result.pages.count) 张图片"
        } catch { self.error = error.localizedDescription }
    }
}
struct PDFPreview: NSViewRepresentable {
    final class Coordinator { var data: Data? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    let data: Data
    let index: Int
    func makeNSView(context: Context) -> PDFView { let v = PDFView(); v.autoScales = true; v.displayMode = .singlePage; v.backgroundColor = NSColor(calibratedRed:0.945,green:0.929,blue:0.961,alpha:1); return v }
    func updateNSView(_ view: PDFView,context: Context) {
        if context.coordinator.data != data { view.document = PDFDocument(data:data); context.coordinator.data = data }
        if let page = view.document?.page(at:index) { view.go(to:page) }
    }
}
enum PressStyle {
    static let ink = Color(red:0.20,green:0.17,blue:0.27)
    static let muted = Color(red:0.43,green:0.39,blue:0.49)
    static let accent = Color(red:0.43,green:0.34,blue:0.64)
    static let lavender = Color(red:0.91,green:0.87,blue:0.95)
}
struct SoftButton: ButtonStyle {
    var prominent = false
    @Environment(\.accessibilityReduceMotion) var reduced
    func makeBody(configuration:Configuration) -> some View {
        configuration.label.font(.system(size:13,weight:.medium)).padding(.horizontal,16).padding(.vertical,12)
            .foregroundStyle(prominent ? Color.white : PressStyle.ink)
            .background(prominent ? PressStyle.accent : Color.white.opacity(0.75),in:RoundedRectangle(cornerRadius:14))
            .overlay(RoundedRectangle(cornerRadius:14).stroke(Color.white.opacity(0.6),lineWidth:1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(reduced ? nil : .easeOut(duration:0.15),value:configuration.isPressed)
    }
}
struct ContentView: View {
    @StateObject var store = Store()
    @State var targeted = false
    @State var appeared = false
    @State var draggedPage: UUID?
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var body: some View {
        HStack(spacing:0) {
            sidebar.frame(width:276)
            VStack(alignment:.leading,spacing:20) {
                preview.frame(maxWidth:.infinity,maxHeight:.infinity)
                exportPanel
            }.padding(28).frame(maxWidth:.infinity,maxHeight:.infinity)
            .background(Color.white.opacity(0.38),in:RoundedRectangle(cornerRadius:28))
            .padding(.vertical,12).padding(.trailing,12)
        }
        .foregroundStyle(PressStyle.ink)
        .background {
            ZStack {
                Color(red:0.94,green:0.92,blue:0.96)
                RadialGradient(colors:[Color(red:0.83,green:0.78,blue:0.94).opacity(0.55),.clear],center:.topLeading,startRadius:10,endRadius:650)
                RadialGradient(colors:[Color(red:0.89,green:0.95,blue:0.84).opacity(0.65),.clear],center:.bottomLeading,startRadius:0,endRadius:450)
                RadialGradient(colors:[Color(red:0.98,green:0.85,blue:0.88).opacity(0.6),.clear],center:.bottomTrailing,startRadius:0,endRadius:450)
            }
        }
        .frame(minWidth:1000,minHeight:680)
        .preferredColorScheme(.light)
        .tint(PressStyle.accent)
        .opacity(appeared ? 1 : 0)
        .onAppear { withAnimation(reduceMotion ? nil : .easeOut(duration:0.3)) {appeared = true} }
        .overlay { if targeted {RoundedRectangle(cornerRadius:24).stroke(PressStyle.accent,lineWidth:3).padding(6).allowsHitTesting(false)} }
        .onDrop(of:[UTType.fileURL.identifier],isTargeted:$targeted) { providers in
            guard !store.busy else { return false }
            let group = DispatchGroup(); let collector = URLCollector()
            for provider in providers { group.enter(); provider.loadItem(forTypeIdentifier:UTType.fileURL.identifier,options:nil) { item,_ in
                if let data = item as? Data,let url = URL(dataRepresentation:data,relativeTo:nil) { collector.add(url) }
                else if let url = item as? URL { collector.add(url) }
                group.leave()
            } }
            group.notify(queue:.main) { store.add(collector.urls) }; return true
        }
        .alert("请检查",isPresented:Binding(get:{store.error != nil},set:{ if !$0 { store.error = nil } })) { Button("好",role:.cancel) {store.error = nil} } message: {Text(store.error ?? "")}
        .onChange(of:store.selected) { store.zoom = 1 }
        .animation(reduceMotion ? nil : .easeInOut(duration:0.2),value:targeted)
    }
    private var sidebar: some View {
        VStack(alignment:.leading,spacing:20) {
            HStack(spacing:10) {
                Image(systemName:"square.stack.3d.up").font(.system(size:23,weight:.medium)).foregroundStyle(PressStyle.accent)
                VStack(alignment:.leading,spacing:3) {Text("作品集压缩器").font(.system(size:17,weight:.semibold));Text("PORTFOLIO PRESS").font(.system(size:9,weight:.medium)).tracking(1.5).foregroundStyle(PressStyle.muted)}
            }.padding(.top,16)
            Button(action:store.choose) {Label("添加图片 / 文件夹",systemImage:"plus") .frame(maxWidth:.infinity)}.buttonStyle(SoftButton()).keyboardShortcut("o").disabled(store.busy)
            HStack {Text("作品页面").font(.system(size:13,weight:.semibold));Spacer();Text("\(store.items.count) 页").font(.caption).foregroundStyle(PressStyle.muted)}
            if store.items.isEmpty {
                VStack(spacing:10) {
                    Image(systemName:"photo.on.rectangle").font(.system(size:26,weight:.light)).foregroundStyle(PressStyle.muted.opacity(0.65))
                    Text("未导入图片").font(.system(size:12)).foregroundStyle(PressStyle.muted)
                }.frame(maxWidth:.infinity).padding(.vertical,36)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing:10) {
                        ForEach(Array(store.items.enumerated()),id:\.element.id) { i,item in
                            Button { store.selected = item.id } label: {
                                VStack(alignment:.leading,spacing:8) {
                                    HStack(spacing:7) {
                                        Text(String(format:"%02d",i+1)).font(.system(size:10,weight:.semibold,design:.monospaced)).foregroundStyle(PressStyle.muted)
                                        Text(item.url.deletingPathExtension().lastPathComponent).font(.system(size:12,weight:.medium)).lineLimit(1)
                                        Spacer(minLength:0)
                                        if store.selected == item.id { Image(systemName:"checkmark.circle.fill").font(.system(size:12)).foregroundStyle(PressStyle.accent) }
                                    }
                                    Image(nsImage:item.thumbnail).resizable()
                                        .aspectRatio(item.thumbnail.size.width / max(1,item.thumbnail.size.height),contentMode:.fit)
                                        .frame(maxWidth:.infinity).clipShape(RoundedRectangle(cornerRadius:8))
                                    HStack {Text("\(item.width) × \(item.height)");Spacer();Text(sizeText(item.bytes))}.font(.system(size:10)).foregroundStyle(PressStyle.muted).monospacedDigit()
                                }.padding(10).foregroundStyle(PressStyle.ink)
                                .background(store.selected == item.id ? Color(red:0.94,green:0.90,blue:0.98) : Color.white.opacity(0.52),in:RoundedRectangle(cornerRadius:16))
                                .overlay(RoundedRectangle(cornerRadius:16).stroke(store.selected == item.id ? PressStyle.accent.opacity(0.6) : .clear,lineWidth:1))
                                .contentShape(RoundedRectangle(cornerRadius:16))
                            }.buttonStyle(.plain)
                            .accessibilityLabel("第 \(i+1) 页，\(item.url.lastPathComponent)")
                            .accessibilityAddTraits(store.selected == item.id ? .isSelected : [])
                            .onDrag { guard !store.busy else {return NSItemProvider()}; draggedPage = item.id;return NSItemProvider(object:item.id.uuidString as NSString) }
                            .onDrop(of:[UTType.text],delegate:PageDropDelegate(target:item.id,dragged:$draggedPage,store:store))
                        }
                    }.padding(2)
                }

            }
            HStack(spacing:8) {
                Button {store.move(-1)} label:{Image(systemName:"arrow.up").frame(width:16)}.help("上移页面").accessibilityLabel("上移页面").disabled(store.selectedIndex == nil || store.selectedIndex == 0)
                Button {store.move(1)} label:{Image(systemName:"arrow.down").frame(width:16)}.help("下移页面").accessibilityLabel("下移页面").disabled(store.selectedIndex == nil || store.selectedIndex == store.items.count-1)
                Spacer()
                Button(action:store.remove) {Image(systemName:"trash").frame(width:16)}.help("移除页面").accessibilityLabel("移除页面").disabled(store.selected == nil)
            }.buttonStyle(SoftButton()).disabled(store.busy)

        }.padding(.horizontal,18).padding(.vertical,20)
    }
    private var preview: some View {
        VStack(spacing:16) {
            HStack {
                Label("页面预览",systemImage:"rectangle.on.rectangle").font(.system(size:12,weight:.medium)).foregroundStyle(PressStyle.muted)
                Spacer()
                HStack(spacing:3) {
                    previewTab("原图",processed:false)
                    previewTab("压缩后",processed:true)
                }.padding(4).background(PressStyle.lavender.opacity(0.45),in:RoundedRectangle(cornerRadius:12))
            }
            if let index = store.selectedIndex {
                Group {
                    if store.processedPreview,let result=store.result {
                        PDFPreview(data:result.pdf,index:index)
                    } else {
                        GeometryReader { geo in
                            ScrollView([.horizontal,.vertical]) {
                                if let image=NSImage(contentsOf:store.items[index].url) {
                                    let ratio = image.size.width / max(1,image.size.height)
                                    let fittedWidth = min(geo.size.width,geo.size.height*ratio)
                                    Image(nsImage:image).resizable().frame(width:fittedWidth*store.zoom,height:fittedWidth/ratio*store.zoom)
                                        .frame(minWidth:geo.size.width,minHeight:geo.size.height)
                                }
                            }
                        }
                    }
                }.background(Color(red:0.945,green:0.929,blue:0.961)).clipShape(RoundedRectangle(cornerRadius:14))
                HStack {
                    Text("\(index+1) / \(store.items.count)").monospacedDigit()
                    Spacer()
                    if store.processedPreview {Text("触控板缩放，检查文字与细节")}
                    else {Text("缩放");Slider(value:$store.zoom,in:1...4).frame(width:110);Text("\(Int(store.zoom*100))%").monospacedDigit().frame(width:38)}
                }.font(.system(size:11)).foregroundStyle(PressStyle.muted)
            } else {
                VStack(spacing:20) {
                    ZStack {
                        RoundedRectangle(cornerRadius:20).fill(PressStyle.lavender.opacity(0.7)).frame(width:116,height:142).rotationEffect(.degrees(-12)).offset(x:-22,y:0)
                        RoundedRectangle(cornerRadius:20).fill(Color.white.opacity(0.9)).frame(width:116,height:142)
                            .overlay { Image(systemName:"photo").font(.system(size:38,weight:.ultraLight)).foregroundStyle(PressStyle.accent) }
                            .rotationEffect(.degrees(9)).offset(x:18,y:5)
                            .shadow(color:PressStyle.accent.opacity(0.10),radius:20,x:0,y:12)
                    }.frame(height:170)
                    Text("拖入图片或整个文件夹").font(.system(size:20,weight:.medium))
                    Text("PNG · JPG · HEIC · TIFF · WebP").font(.system(size:12)).lineSpacing(7).multilineTextAlignment(.center).fixedSize(horizontal:false,vertical:true).foregroundStyle(PressStyle.muted)
                    Button("选择文件夹",action:store.choose).buttonStyle(SoftButton())
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
            }
        }.padding(20).background(Color.white.opacity(0.64),in:RoundedRectangle(cornerRadius:24))
        .overlay(RoundedRectangle(cornerRadius:24).stroke(Color.white.opacity(0.8),lineWidth:1))
        .shadow(color:PressStyle.accent.opacity(0.04),radius:20,x:0,y:8)
    }
    private func previewTab(_ title:String,processed:Bool) -> some View {
        Button { withAnimation(reduceMotion ? nil : .easeInOut(duration:0.16)) {store.processedPreview = processed} } label: {
            Text(title).font(.system(size:12,weight:.medium)).padding(.horizontal,14).padding(.vertical,7)
                .foregroundStyle(store.processedPreview == processed ? PressStyle.accent : PressStyle.muted)
                .background(store.processedPreview == processed ? Color.white : .clear,in:RoundedRectangle(cornerRadius:9))
        }.buttonStyle(.plain).disabled(processed && store.result == nil)
        .opacity(processed && store.result == nil ? 0.4 : 1)
        .accessibilityAddTraits(store.processedPreview == processed ? .isSelected : [])
    }
    private var exportPanel: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack(spacing:20) {
                VStack(alignment:.leading,spacing:6) {Text("原始大小").font(.system(size:11)).foregroundStyle(PressStyle.muted);Text(sizeText(store.originalSize)).font(.system(size:18,weight:.medium)).monospacedDigit()}
                Image(systemName:"arrow.right").foregroundStyle(PressStyle.muted.opacity(0.6))
                VStack(alignment:.leading,spacing:6) {Text("目标体积").font(.system(size:11)).foregroundStyle(PressStyle.muted);Picker("目标体积",selection:$store.target){Text("5 MB").tag(5.0);Text("10 MB").tag(10.0);Text("15 MB").tag(15.0);Text("20 MB").tag(20.0);Text("30 MB").tag(30.0)}.labelsHidden().frame(width:95).disabled(store.busy).onChange(of:store.target){store.invalidate()}}
                VStack(alignment:.leading,spacing:6) {Text("压缩档位").font(.system(size:11)).foregroundStyle(PressStyle.muted);Picker("压缩档位",selection:$store.minimumQuality){Text("清晰优先").tag(0.45);Text("均衡 · 推荐").tag(0.30);Text("小文件优先").tag(0.20)}.labelsHidden().frame(width:120).disabled(store.busy).onChange(of:store.minimumQuality){store.invalidate()}}
                Spacer(minLength:0)
                if let result=store.result {
                    VStack(alignment:.trailing,spacing:5) {Text(sizeText(result.pdf.count)).font(.system(size:23,weight:.semibold)).monospacedDigit();Label(result.targetMet ? "已达到目标" : "超过目标",systemImage:result.targetMet ? "checkmark.circle" : "exclamationmark.triangle").font(.system(size:11)).foregroundStyle(result.targetMet ? PressStyle.accent : Color(red:0.65,green:0.32,blue:0.12))}
                }
            }
            HStack {
                VStack(alignment:.leading,spacing:6) {
                    if store.busy {ProgressView(value:store.progress).tint(PressStyle.accent).frame(width:200)}
                    Text(store.status).font(.system(size:11)).foregroundStyle(PressStyle.muted).lineLimit(2)

                }.frame(maxWidth:.infinity,alignment:.leading)
                if store.result != nil {
                    Button("导出图片",action:store.saveImages).buttonStyle(SoftButton())
                    Button(action:store.save){Label("导出 PDF",systemImage:"arrow.up.doc")}.buttonStyle(SoftButton(prominent:true)).keyboardShortcut("s")
                } else {
                    Button(action:store.build){Label(store.busy ? "正在压缩…" : "生成 PDF",systemImage:store.busy ? "ellipsis" : "arrow.right")}.buttonStyle(SoftButton(prominent:true)).disabled(store.items.isEmpty || store.busy).keyboardShortcut(.return,modifiers:.command)
                }
            }
        }.padding(20).background(Color.white.opacity(0.65),in:RoundedRectangle(cornerRadius:24))
    }
}
struct PageDropDelegate: DropDelegate {
    let target: UUID
    @Binding var dragged: UUID?
    let store: Store
    func validateDrop(info:DropInfo) -> Bool { dragged != nil && !store.busy }
    func dropEntered(info:DropInfo) {
        guard !store.busy,let dragged,dragged != target,
              let from=store.items.firstIndex(where:{$0.id == dragged}),let to=store.items.firstIndex(where:{$0.id == target}) else {return}
        store.items.move(fromOffsets:IndexSet(integer:from),toOffset:to > from ? to+1 : to)
        store.invalidate()
    }
    func dropUpdated(info:DropInfo) -> DropProposal? {DropProposal(operation:.move)}
    func performDrop(info:DropInfo) -> Bool { dragged = nil;return true }
}
final class URLCollector: @unchecked Sendable {
    private let lock = NSLock(); private var values: [URL] = []
    func add(_ url: URL) { lock.lock(); values.append(url); lock.unlock() }
    var urls: [URL] { lock.lock(); defer {lock.unlock()}; return values }
}
@main struct PortfolioPressApp: App {
    var body: some Scene {
        WindowGroup { ContentView().onAppear {NSApp.activate(ignoringOtherApps:true)} }.defaultSize(width:1140,height:820)
        .commands { CommandGroup(replacing:.newItem) {} }
    }
}
