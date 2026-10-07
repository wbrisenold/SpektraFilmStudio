import SwiftUI
import WebKit
import AppKit
import Foundation

/// Hosts the real PhotoCraft web application inside SpektraFilm Studio.
///
/// PhotoCraft's web target runs the same `PhotocraftApp`/egui UI as its desktop
/// application. The web build is produced from the pinned PhotoCraft checkout by
/// `scripts/bootstrap_photocraft_web.sh` and bundled under
/// `Contents/Resources/PhotoCraftWeb`.
struct PhotoCraftWorkspaceView: View {
    @ObservedObject var model: AppModel
    @State private var reloadToken = UUID()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("PhotoCraft")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Full layered pixel editor • local • powered by the bundled PhotoCraft build")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    reloadToken = UUID()
                } label: {
                    Label("Reload PhotoCraft", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Reloads the embedded PhotoCraft workspace without changing SpektraFilm edits.")
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(StudioPalette.panel)

            Divider().opacity(0.65)

            PhotoCraftWebView(reloadToken: reloadToken)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct PhotoCraftWebView: NSViewRepresentable {
    let reloadToken: UUID

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let handler = PhotoCraftAssetSchemeHandler()
        configuration.setURLSchemeHandler(handler, forURLScheme: PhotoCraftAssetSchemeHandler.scheme)
        context.coordinator.schemeHandler = handler

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false

        context.coordinator.loadPhotoCraft(in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastReloadToken != reloadToken {
            context.coordinator.lastReloadToken = reloadToken
            context.coordinator.loadPhotoCraft(in: webView)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var schemeHandler: PhotoCraftAssetSchemeHandler?
        var lastReloadToken: UUID?

        func loadPhotoCraft(in webView: WKWebView) {
            guard PhotoCraftAssetSchemeHandler.bundleRoot != nil else {
                webView.loadHTMLString(Self.missingBundleHTML, baseURL: nil)
                return
            }
            guard let url = URL(string: "\(PhotoCraftAssetSchemeHandler.scheme)://app/index.html") else {
                webView.loadHTMLString(Self.missingBundleHTML, baseURL: nil)
                return
            }
            webView.load(URLRequest(url: url))
        }

        func webView(
            _ webView: WKWebView,
            runOpenPanelWith parameters: WKOpenPanelParameters,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void
        ) {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.canChooseDirectories = parameters.allowsDirectories
            panel.canChooseFiles = true
            panel.begin { response in
                completionHandler(response == .OK ? panel.urls : nil)
            }
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            webView.loadHTMLString(Self.failureHTML(error.localizedDescription), baseURL: nil)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            webView.loadHTMLString(Self.failureHTML(error.localizedDescription), baseURL: nil)
        }

        private static var missingBundleHTML: String {
            failureHTML(
                "The PhotoCraft web bundle is missing. Run BUILD_ON_MAC.command; "
                + "the build now generates and packages PhotoCraft automatically."
            )
        }

        private static func failureHTML(_ message: String) -> String {
            let escaped = message
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            return """
            <!doctype html>
            <html>
            <head>
              <meta charset="utf-8">
              <style>
                html,body{height:100%;margin:0;background:#202020;color:#ddd;font:14px -apple-system,system-ui,sans-serif}
                main{height:100%;display:flex;align-items:center;justify-content:center}
                section{max-width:560px;padding:28px;border:1px solid #444;border-radius:12px;background:#282828}
                h2{margin-top:0;color:white}
                code{color:#b7d8ff}
              </style>
            </head>
            <body><main><section>
              <h2>PhotoCraft could not start</h2>
              <p>\(escaped)</p>
              <p>The embedded editor is built from the pinned open-source PhotoCraft checkout and stays local to this Mac.</p>
            </section></main></body>
            </html>
            """
        }
    }
}

/// Serves PhotoCraft's bundled JS/WASM/assets to WKWebView under a local custom
/// scheme. Using a real scheme with correct MIME types is more reliable for
/// WebAssembly than loading the generated site directly from `file://`.
private final class PhotoCraftAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "spektraphotocraft"

    static var bundleRoot: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let root = resources.appendingPathComponent("PhotoCraftWeb", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return root
    }

    private let lock = NSLock()
    private var stopped = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let taskID = ObjectIdentifier(urlSchemeTask as AnyObject)
        guard let root = Self.bundleRoot,
              let requestURL = urlSchemeTask.request.url else {
            finish(task: urlSchemeTask, id: taskID, error: NSError(
                domain: "SpektraFilm.PhotoCraft",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "PhotoCraft resources are missing."]
            ))
            return
        }

        var relative = requestURL.path
        if relative.hasPrefix("/") { relative.removeFirst() }
        if relative.isEmpty { relative = "index.html" }

        let decoded = relative.removingPercentEncoding ?? relative
        guard !decoded.split(separator: "/").contains("..") else {
            finish(task: urlSchemeTask, id: taskID, error: NSError(
                domain: "SpektraFilm.PhotoCraft",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid PhotoCraft asset path."]
            ))
            return
        }

        let fileURL = root.appendingPathComponent(decoded, isDirectory: false)

        do {
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            guard !isStopped(taskID) else { return }

            let response = HTTPURLResponse(
                url: requestURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": Self.mimeType(for: fileURL.pathExtension),
                    "Cache-Control": "no-cache",
                    "Cross-Origin-Resource-Policy": "same-origin"
                ]
            )!

            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            finish(task: urlSchemeTask, id: taskID, error: error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        lock.lock()
        stopped.insert(ObjectIdentifier(urlSchemeTask as AnyObject))
        lock.unlock()
    }

    private func isStopped(_ id: ObjectIdentifier) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped.contains(id)
    }

    private func finish(task: WKURLSchemeTask, id: ObjectIdentifier, error: Error) {
        guard !isStopped(id) else { return }
        task.didFailWithError(error)
    }

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "wasm": return "application/wasm"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }
}
