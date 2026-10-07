import SwiftUI
import AppKit
import Foundation
import UniformTypeIdentifiers

// SpektraFilm Creation Suite. Independent native code; OpenPost is a feature reference.
// Project files and exports stay local and do not require a user account.

enum CreationLayout: String, Codable, CaseIterable, Identifiable {
    case single = "Single", diptych = "Diptych", vertical = "Stacked", triptych = "Triptych"
    case grid = "Four Grid", editorial = "Editorial", overlap = "Overlapping", doubleExposure = "Double Exposure"
    var id: String { rawValue }
}
enum CreationFrame: String, Codable, CaseIterable, Identifiable {
    case none = "None", white = "White Border", black = "Black Border", ivory = "Gallery Ivory"
    case film = "35mm Film", negative = "Film Negative", instant = "Instant Print", editorial = "Editorial Mat", keyline = "Thin Keyline"
    var id: String { rawValue }
}
enum CreationType: String, Codable, CaseIterable, Identifiable {
    case editorial = "Editorial", serif = "Fine Art Serif", modern = "Modern", bold = "Bold Headline", mono = "Monospaced", smallCaps = "Small Caps"
    var id: String { rawValue }
}
enum CreationCanvasSize: String, Codable, CaseIterable, Identifiable {
    case square = "Square 1080 × 1080", portrait = "Portrait 1080 × 1350", story = "Story 1080 × 1920"
    case wide = "Wide 1920 × 1080", pin = "Pin 1000 × 1500", custom = "Custom"
    var id: String { rawValue }
    var pixels: (Int, Int) {
        switch self {
        case .square: (1080, 1080)
        case .portrait: (1080, 1350)
        case .story: (1080, 1920)
        case .wide: (1920, 1080)
        case .pin: (1000, 1500)
        case .custom: (1080, 1350)
        }
    }
}
struct CreationText: Identifiable, Codable, Equatable {
    var id = UUID()
    var content: String = "YOUR HEADLINE"
    var style: CreationType = .editorial
    var size: Double = 60
    var x: Double = 0.50
    var y: Double = 0.08
    var opacity: Double = 1
    var isLight = true
    var alignment: Int = 1
}
struct CreationPage: Identifiable, Codable, Equatable {
    var id = UUID()
    var imagePaths: [String] = []
    var layout: CreationLayout = .single
    var frame: CreationFrame = .none
    var canvas: CreationCanvasSize = .portrait
    var customWidth: Int = 1080
    var customHeight: Int = 1350
    var margin: Double = 0.045
    var gutter: Double = 0.018
    var blendOpacity: Double = 0.55
    var frameThickness: Double = 0.055
    var texts: [CreationText] = []
    var backgroundDark = true
    var title: String = "Page"
    var width: Int { canvas == .custom ? min(6000, max(200, customWidth)) : canvas.pixels.0 }
    var height: Int { canvas == .custom ? min(6000, max(200, customHeight)) : canvas.pixels.1 }
}
struct CreationDocument: Codable, Equatable {
    var name = "Untitled Carousel"
    var pages: [CreationPage] = [CreationPage()]
    var version: Int = 1
}

enum CreationRenderer {
    static func preview(_ page: CreationPage, longEdge: Int = 850) -> NSImage? {
        let scale = min(1, Double(longEdge) / Double(max(page.width, page.height)))
        return render(page, width: max(1, Int(Double(page.width) * scale)), height: max(1, Int(Double(page.height) * scale)))
    }

    static func render(_ page: CreationPage, width: Int, height: Int) -> NSImage? {
        guard width > 0, height > 0, width <= 6000, height <= 6000,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { context.flushGraphics(); NSGraphicsContext.restoreGraphicsState() }
        let w = CGFloat(width), h = CGFloat(height)
        let canvas = CGRect(x: 0, y: 0, width: w, height: h)
        (page.backgroundDark ? NSColor(calibratedWhite: 0.055, alpha: 1) : NSColor.white).setFill()
        NSBezierPath(rect: canvas).fill()
        let pad = CGFloat(max(0, min(0.30, page.margin))) * min(w, h)
        let gap = CGFloat(max(0, min(0.25, page.gutter))) * min(w, h)
        let inner = canvas.insetBy(dx: pad, dy: pad)
        let slots = layoutSlots(page.layout, in: inner, gap: gap)
        for (index, rect) in slots.enumerated() {
            let fileIndex = page.layout == .doubleExposure ? min(index, page.imagePaths.count - 1) : index
            guard fileIndex >= 0, page.imagePaths.indices.contains(fileIndex),
                  let source = NSImage(contentsOfFile: page.imagePaths[fileIndex]) else { continue }
            let operation: NSCompositingOperation = page.layout == .doubleExposure && index > 0 ? .screen : .sourceOver
            drawFill(source, into: rect, opacity: page.layout == .doubleExposure && index > 0 ? CGFloat(page.blendOpacity) : 1, operation: operation)
        }
        drawFrame(page.frame, canvas: canvas, inner: inner, size: CGSize(width: w, height: h), thickness: CGFloat(page.frameThickness))
        drawText(page.texts, in: canvas, factor: w / CGFloat(max(1, page.width)))
        let output = NSImage(size: NSSize(width: width, height: height))
        output.addRepresentation(rep)
        return output
    }

    private static func layoutSlots(_ layout: CreationLayout, in r: CGRect, gap: CGFloat) -> [CGRect] {
        switch layout {
        case .single: return [r]
        case .doubleExposure: return [r, r]
        case .diptych:
            let x = (r.width - gap) / 2
            return [CGRect(x: r.minX, y: r.minY, width: x, height: r.height), CGRect(x: r.minX + x + gap, y: r.minY, width: x, height: r.height)]
        case .vertical:
            let y = (r.height - gap) / 2
            return [CGRect(x: r.minX, y: r.minY, width: r.width, height: y), CGRect(x: r.minX, y: r.minY + y + gap, width: r.width, height: y)]
        case .triptych:
            let x = (r.width - 2 * gap) / 3
            return (0..<3).map { CGRect(x: r.minX + CGFloat($0) * (x + gap), y: r.minY, width: x, height: r.height) }
        case .grid:
            let x = (r.width - gap) / 2, y = (r.height - gap) / 2
            return [CGRect(x:r.minX,y:r.minY,width:x,height:y),CGRect(x:r.minX+x+gap,y:r.minY,width:x,height:y),CGRect(x:r.minX,y:r.minY+y+gap,width:x,height:y),CGRect(x:r.minX+x+gap,y:r.minY+y+gap,width:x,height:y)]
        case .editorial:
            let major = r.width * 0.65
            let minor = r.width - major - gap
            let half = (r.height - gap) / 2
            return [CGRect(x:r.minX,y:r.minY,width:major,height:r.height),CGRect(x:r.minX+major+gap,y:r.minY,width:minor,height:half),CGRect(x:r.minX+major+gap,y:r.minY+half+gap,width:minor,height:half)]
        case .overlap:
            return [CGRect(x:r.minX,y:r.minY+r.height*0.16,width:r.width*0.72,height:r.height*0.78),CGRect(x:r.minX+r.width*0.38,y:r.minY,width:r.width*0.60,height:r.height*0.69)]
        }
    }

    private static func drawFill(_ image: NSImage, into rect: CGRect, opacity: CGFloat, operation: NSCompositingOperation) {
        guard image.size.width > 0, image.size.height > 0, rect.width > 0, rect.height > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: rect).addClip()
        let scale = max(rect.width / image.size.width, rect.height / image.size.height)
        let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let fill = CGRect(x: rect.midX - drawSize.width / 2, y: rect.midY - drawSize.height / 2, width: drawSize.width, height: drawSize.height)
        image.draw(in: fill, from: .zero, operation: operation, fraction: opacity, respectFlipped: false, hints: nil)
    }

    private static func drawFrame(_ style: CreationFrame, canvas: CGRect, inner: CGRect, size: CGSize, thickness: CGFloat) {
        guard style != .none else { return }
        let t = max(1, min(size.width, size.height) * CGFloat(min(0.35, max(0.005, thickness))))
        let color: NSColor
        switch style {
        case .white, .instant, .editorial: color = .white
        case .ivory: color = NSColor(calibratedRed: 0.92, green: 0.89, blue: 0.81, alpha: 1)
        case .film, .negative, .black: color = NSColor(calibratedWhite: 0.03, alpha: 1)
        case .keyline: color = .white
        case .none: return
        }
        color.setStroke()
        let border = NSBezierPath(rect: canvas.insetBy(dx: t / 2, dy: t / 2))
        border.lineWidth = style == .keyline ? max(1, t * 0.07) : t
        border.stroke()
        if style == .film || style == .negative {
            let holes = max(6, Int(size.height / max(6, t * 2)))
            for y in 0..<holes {
                let cy = (CGFloat(y) + 0.5) / CGFloat(holes) * size.height
                for x in [t * 0.35, size.width - t * 0.35] {
                    (style == .negative ? NSColor.white : NSColor(calibratedWhite: 0.85, alpha: 1)).setFill()
                    NSBezierPath(roundedRect: CGRect(x: x - t * 0.11, y: cy - t * 0.21, width: t * 0.22, height: t * 0.42), xRadius: t * 0.035, yRadius: t * 0.035).fill()
                }
            }
        }
        if style == .instant {
            color.setFill()
            NSBezierPath(rect: CGRect(x: 0, y: 0, width: size.width, height: t * 1.8)).fill()
        }
    }

    private static func drawText(_ texts: [CreationText], in canvas: CGRect, factor: CGFloat) {
        for text in texts where !text.content.isEmpty {
            let pointSize = CGFloat(max(9, min(260, text.size))) * factor
            let font: NSFont
            switch text.style {
            case .editorial: font = NSFont(name:"HelveticaNeue-Light", size:pointSize) ?? .systemFont(ofSize: pointSize)
            case .serif: font = NSFont(name:"TimesNewRomanPSMT", size:pointSize) ?? .systemFont(ofSize:pointSize)
            case .modern: font = .systemFont(ofSize:pointSize, weight:.medium)
            case .bold: font = .systemFont(ofSize:pointSize, weight:.black)
            case .mono: font = .monospacedSystemFont(ofSize:pointSize, weight:.medium)
            case .smallCaps: font = .systemFont(ofSize:pointSize, weight:.semibold)
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = text.alignment == 0 ? .left : (text.alignment == 2 ? .right : .center)
            paragraph.lineBreakMode = .byWordWrapping
            let attributes: [NSAttributedString.Key: Any] = [
                .font:font, .foregroundColor: (text.isLight ? NSColor.white : NSColor.black).withAlphaComponent(CGFloat(text.opacity)),
                .paragraphStyle: paragraph
            ]
            let bw = canvas.width * 0.90
            let bh = canvas.height * 0.35
            let box = CGRect(x: canvas.width * CGFloat(text.x) - bw / 2,
                             y: canvas.height * (1 - CGFloat(text.y)) - bh,
                             width: bw, height: bh)
            (text.content as NSString).draw(in: box, withAttributes: attributes)
        }
    }
}

struct CreationWorkspaceView: View {
    @ObservedObject var model: AppModel
    @State private var document = CreationDocument()
    @State private var selectedPage = UUID()
    @State private var selectedText: UUID?
    @State private var preview: NSImage?
    @State private var selectedSource = ""
    @State private var outputStatus = "Create carousel, collage, film frame, or double exposure"
    @State private var isExporting = false
    @State private var showGuides = false
    @State private var exportJPEG = false
    @State private var jpegQuality = 0.92

    private var pageIndex: Int? { document.pages.firstIndex(where: { $0.id == selectedPage }) }
    private var page: CreationPage { pageIndex.map { document.pages[$0] } ?? CreationPage() }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("Creation name", text: $document.name).font(.headline).frame(maxWidth: 250)
                Button("Add selected photos") { addSelectedPhotos() }
                Button("Import photos…") { chooseImages() }
                Spacer()
                Button("Open design…") { openDesign() }
                Button("Save design…") { saveDesign() }
                Button("Export ordered pages…") { exportPages() }.disabled(isExporting || document.pages.isEmpty)
            }
            .buttonStyle(.bordered).padding(12)
            Divider()
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("PAGES • EXPORT ORDER").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(Array(document.pages.enumerated()), id: \.element.id) { offset, entry in
                            HStack(spacing: 5) {
                                Button { selectedPage = entry.id } label: {
                                    VStack(alignment:.leading,spacing:3) {
                                        Text(String(format:"%02d",offset+1) + "  " + entry.title).lineLimit(1)
                                        Text(entry.canvas.rawValue).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth:.infinity,alignment:.leading)
                                    .padding(8)
                                    .background(selectedPage == entry.id ? Color.accentColor.opacity(0.18):Color.clear, in:RoundedRectangle(cornerRadius:7))
                                }.buttonStyle(.plain)
                                Button { movePage(offset, -1) } label: { Image(systemName:"arrow.up") }.disabled(offset == 0)
                                Button { movePage(offset, 1) } label: { Image(systemName:"arrow.down") }.disabled(offset == document.pages.count - 1)
                            }
                            .font(.caption)
                        }
                        Divider()
                        HStack {
                            Button("New") { addPage() }
                            Button("Duplicate") { duplicatePage() }
                            Button("Remove") { removePage() }.disabled(document.pages.count <= 1)
                        }.controlSize(.small)
                        Text("Pages export in exactly this order, with numbered filenames.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }.padding(10)
                }.frame(width:230)
                Divider()
                VStack(spacing: 8) {
                    GeometryReader { geometry in
                        ZStack {
                            Color.black.opacity(0.8)
                            if let preview {
                                Image(nsImage: preview).resizable().aspectRatio(contentMode:.fit)
                                    .frame(maxWidth: geometry.size.width - 30, maxHeight: geometry.size.height - 30)
                                    .overlay(alignment:.center) {
                                        if showGuides {
                                            Rectangle().stroke(Color.white.opacity(0.5),style:StrokeStyle(lineWidth:1,dash:[6,5]))
                                                .padding(30).allowsHitTesting(false)
                                        }
                                    }
                            } else { Text("Add a photo to this page").foregroundStyle(.secondary) }
                        }.frame(maxWidth:.infinity,maxHeight:.infinity)
                    }
                    Text("\(page.width) × \(page.height) • \(page.layout.rawValue) • \(document.pages.count) pages")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(outputStatus).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }.padding(12).frame(maxWidth:.infinity)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("PAGE DESIGN").font(.caption.weight(.semibold))
                        TextField("Page title",text:pageBinding(\.title))
                        Picker("Canvas",selection:pageBinding(\.canvas)) {
                            ForEach(CreationCanvasSize.allCases) { Text($0.rawValue).tag($0) }
                        }
                        if page.canvas == .custom {
                            Stepper("Width \(page.customWidth)",value:pageBinding(\.customWidth),in:200...6000,step:10)
                            Stepper("Height \(page.customHeight)",value:pageBinding(\.customHeight),in:200...6000,step:10)
                        }
                        Picker("Layout",selection:pageBinding(\.layout)) {
                            ForEach(CreationLayout.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Picker("Frame",selection:pageBinding(\.frame)) {
                            ForEach(CreationFrame.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Toggle("Dark background",isOn:pageBinding(\.backgroundDark))
                        Toggle("Safe-area guides",isOn:$showGuides)
                        valueSlider("Page margin",value:pageBinding(\.margin),range:0...0.25,reset:0.045)
                        valueSlider("Image gutter",value:pageBinding(\.gutter),range:0...0.10,reset:0.018)
                        valueSlider("Border thickness",value:pageBinding(\.frameThickness),range:0.005...0.25,reset:0.055)
                        if page.layout == .doubleExposure {
                            valueSlider("Second exposure opacity",value:pageBinding(\.blendOpacity),range:0...1,reset:0.55)
                        }
                        Divider()
                        Text("PAGE PHOTOS").font(.caption.weight(.semibold))
                        ForEach(Array(page.imagePaths.enumerated()), id: \.offset) { idx, path in
                            HStack {
                                Text(URL(fileURLWithPath:path).lastPathComponent).lineLimit(1)
                                Spacer()
                                Button { moveImage(idx,-1) } label: { Image(systemName:"arrow.up") }.disabled(idx == 0).buttonStyle(.plain)
                                Button { moveImage(idx,1) } label: { Image(systemName:"arrow.down") }.disabled(idx == page.imagePaths.count - 1).buttonStyle(.plain)
                                Button { changePage { $0.imagePaths.remove(at:idx) } } label: { Image(systemName:"xmark.circle") }.buttonStyle(.plain)
                            }.font(.caption2)
                        }
                        Button("Add library photo") { addSelectedPhotoToPage() }
                        Button("Choose files…") { chooseImages(addToPage:true) }
                        Divider()
                        HStack {
                            Text("TEXT LAYERS").font(.caption.weight(.semibold))
                            Spacer()
                            Button { addText() } label: { Image(systemName:"plus.circle") }
                        }
                        ForEach(page.texts) { layer in
                            VStack(alignment:.leading,spacing:5) {
                                HStack {
                                    TextField("Text",text:textBinding(layer.id,\.content))
                                    Button { changePage { $0.texts.removeAll{$0.id == layer.id} } } label: { Image(systemName:"trash") }
                                }
                                Picker("Style",selection:textBinding(layer.id,\.style)) {
                                    ForEach(CreationType.allCases) { Text($0.rawValue).tag($0) }
                                }
                                HStack {
                                    Text("Size"); Slider(value:textBinding(layer.id,\.size),in:12...180)
                                }
                                HStack {
                                    Text("X"); Slider(value:textBinding(layer.id,\.x),in:0...1)
                                }
                                HStack {
                                    Text("Y"); Slider(value:textBinding(layer.id,\.y),in:0...1)
                                }
                                Toggle("White text",isOn:textBinding(layer.id,\.isLight))
                                Picker("Alignment",selection:textBinding(layer.id,\.alignment)) {
                                    Text("Left").tag(0); Text("Center").tag(1); Text("Right").tag(2)
                                }
                                valueSlider("Opacity",value:textBinding(layer.id,\.opacity),range:0...1,reset:1)
                            }.padding(8).background(Color.secondary.opacity(0.06),in:RoundedRectangle(cornerRadius:8))
                        }
                        Divider()
                        Toggle("Export JPEG",isOn:$exportJPEG)
                        if exportJPEG { valueSlider("JPEG quality",value:$jpegQuality,range:0.5...1,reset:0.92) }
                        Menu("Quick text presets") {
                            Button("Editorial Cover") { addText("THE STORY",.serif,90,0.10) }
                            Button("Minimal Credit") { addText("PHOTOGRAPHY / 2026",.mono,25,0.93) }
                            Button("Big Statement") { addText("BOLD IDEAS.",.bold,115,0.18) }
                            Button("Quote") { addText("A MOMENT WORTH KEEPING",.editorial,50,0.82) }
                            Button("Carousel CTA") { addText("SWIPE FOR MORE →",.modern,44,0.91) }
                        }
                    }.padding(13)
                }.frame(width:300)
            }
        }
        .onAppear { if !document.pages.contains(where: { $0.id == selectedPage }) { selectedPage = document.pages[0].id }; refresh() }
        .onChange(of: document) { _, _ in refresh() }
        .onChange(of: selectedPage) { _, _ in refresh() }
    }

    private func changePage(_ action:(inout CreationPage)->Void) {
        guard let i = pageIndex else { return }
        action(&document.pages[i])
    }
    private func pageBinding<T>(_ path:WritableKeyPath<CreationPage,T>) -> Binding<T> {
        Binding(get:{page[keyPath:path]},set:{value in changePage{$0[keyPath:path]=value}})
    }
    private func textBinding<T>(_ id:UUID,_ path:WritableKeyPath<CreationText,T>)->Binding<T> {
        Binding(get:{page.texts.first(where:{$0.id == id})?[keyPath:path] ?? CreationText()[keyPath:path]},
                set:{value in changePage{ p in if let i=p.texts.firstIndex(where:{$0.id == id}){p.texts[i][keyPath:path]=value}}})
    }
    private func valueSlider(_ label:String,value:Binding<Double>,range:ClosedRange<Double>,reset:Double)->some View {
        VStack(alignment:.leading,spacing:3) {
            HStack { Text(label); Spacer();Text(String(format:"%.2f",value.wrappedValue)).monospacedDigit()
                Button { value.wrappedValue=reset } label:{Image(systemName:"arrow.counterclockwise")}.buttonStyle(.plain).help("Reset \(label)")
            }
            Slider(value:value,in:range).onTapGesture(count:2){value.wrappedValue=reset}
        }.font(.caption)
    }
    private func refresh() { preview=CreationRenderer.preview(page) }
    private func addPage() {
        guard document.pages.count < 35 else { outputStatus="35-page limit reached";return }
        var new=CreationPage();new.canvas=page.canvas;new.title="Page \(document.pages.count+1)"
        if let i=pageIndex { document.pages.insert(new,at:i+1) } else {document.pages.append(new)}
        selectedPage=new.id
    }
    private func duplicatePage() {
        guard document.pages.count < 35 else {return}
        var other=page;other.id=UUID();other.title += " Copy";other.texts=other.texts.map {t in var v=t;v.id=UUID();return v}
        document.pages.insert(other,at:(pageIndex ?? 0)+1);selectedPage=other.id
    }
    private func removePage() {
        guard document.pages.count > 1,let i=pageIndex else{return}
        document.pages.remove(at:i);selectedPage=document.pages[min(i,document.pages.count-1)].id
    }
    private func movePage(_ i:Int,_ direction:Int) {
        let j=i+direction;guard document.pages.indices.contains(i),document.pages.indices.contains(j) else{return}
        document.pages.swapAt(i,j)
    }
    private func moveImage(_ i:Int,_ direction:Int) {
        changePage { p in let j=i+direction;guard p.imagePaths.indices.contains(i),p.imagePaths.indices.contains(j) else{return};p.imagePaths.swapAt(i,j) }
    }
    private func addText(_ content:String="YOUR HEADLINE",_ style:CreationType = .editorial,_ size:Double=60,_ y:Double=0.08) {
        var text=CreationText();text.content=content;text.style=style;text.size=size;text.y=y
        changePage{$0.texts.append(text)}
    }
    private func addSelectedPhotoToPage() {
        guard let url=model.selectedImage?.url,FileManager.default.fileExists(atPath:url.path) else {outputStatus="Select a photo in Library first";return}
        changePage{$0.imagePaths.append(url.path)}
    }
    private func addSelectedPhotos() {
        let photos=model.project.images.filter{model.librarySelection.contains($0.id)}
        guard !photos.isEmpty else {addSelectedPhotoToPage();return}
        for photo in photos.prefix(max(0,35-document.pages.count+1)) {
            guard FileManager.default.fileExists(atPath:photo.url.path) else {continue}
            if page.imagePaths.isEmpty {changePage{$0.imagePaths=[photo.url.path]}}
            else if document.pages.count < 35 {var p=CreationPage();p.imagePaths=[photo.url.path];p.title=photo.fileName;p.canvas=page.canvas;document.pages.append(p)}
        }
        outputStatus="Library photos added in project order"
    }
    private func chooseImages(addToPage:Bool=true) {
        let open=NSOpenPanel();open.allowedContentTypes=[.image];open.allowsMultipleSelection=true;open.canChooseDirectories=false
        guard open.runModal() == .OK else {return}
        if addToPage {changePage{$0.imagePaths.append(contentsOf:open.urls.map(\.path))}}
        else {for url in open.urls.prefix(35-document.pages.count) {var p=CreationPage();p.imagePaths=[url.path];document.pages.append(p)}}
    }
    private func saveDesign() {
        let panel=NSSavePanel();panel.allowedContentTypes=[.json];panel.nameFieldStringValue=document.name+".spektcreate.json"
        guard panel.runModal() == .OK,let url=panel.url else{return}
        do {let data=try JSONEncoder().encode(document);try data.write(to:url,options:.atomic);outputStatus="Saved \(url.lastPathComponent)"}
        catch {outputStatus="Save failed: \(error.localizedDescription)"}
    }
    private func openDesign() {
        let panel=NSOpenPanel();panel.allowedContentTypes=[.json];panel.allowsMultipleSelection=false
        guard panel.runModal() == .OK,let url=panel.url else{return}
        do {let d=try JSONDecoder().decode(CreationDocument.self,from:Data(contentsOf:url));guard !d.pages.isEmpty, d.pages.count <= 35 else{outputStatus="Invalid page count";return};document=d;selectedPage=d.pages[0].id;outputStatus="Opened \(url.lastPathComponent)"}
        catch {outputStatus="Open failed: \(error.localizedDescription)"}
    }
    private func exportPages() {
        let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.prompt="Export here"
        guard panel.runModal() == .OK,let dir=panel.url else{return}
        isExporting=true
        defer {isExporting=false}
        var saved=0
        for (index,pg) in document.pages.enumerated() {
            guard let image=CreationRenderer.render(pg,width:pg.width,height:pg.height),
                  let tiff=image.tiffRepresentation,let bitmap=NSBitmapImageRep(data:tiff),
                  let data=bitmap.representation(using:exportJPEG ? .jpeg : .png,properties:exportJPEG ? [.compressionFactor:jpegQuality] : [:]) else{continue}
            let slug=document.name.replacingOccurrences(of:"[^a-zA-Z0-9_-]",with:"-",options:.regularExpression)
            let file=dir.appendingPathComponent(String(format:"%02d_%@.%@",index+1,slug,exportJPEG ? "jpg" : "png"))
            do {try data.write(to:file,options:.atomic);saved += 1} catch {outputStatus="Export error: \(error.localizedDescription)";return}
        }
        outputStatus="Exported \(saved) of \(document.pages.count) \(exportJPEG ? "JPEG" : "PNG") pages in carousel order"
    }
}
