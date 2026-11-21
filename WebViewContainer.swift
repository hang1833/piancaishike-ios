import SwiftUI
import WebKit

struct WebViewContainer: UIViewRepresentable {
    @ObservedObject var storeManager: StoreManager

    func makeCoordinator() -> Coordinator {
        Coordinator(storeManager: storeManager)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "iosBilling")
        config.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 4/255, green: 11/255, blue: 14/255, alpha: 1)
        webView.scrollView.backgroundColor = UIColor(red: 4/255, green: 11/255, blue: 14/255, alpha: 1)
        webView.scrollView.bounces = false
        webView.navigationDelegate = context.coordinator

        context.coordinator.webView = webView
        storeManager.webDelegate = context.coordinator

        if let htmlURL = Bundle.main.url(forResource: "index", withExtension: "html") {
            webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        }

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WebBillingDelegate {
        let storeManager: StoreManager
        weak var webView: WKWebView?

        init(storeManager: StoreManager) {
            self.storeManager = storeManager
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "iosBilling",
                  let body = message.body as? [String: Any],
                  let action = body["action"] as? String else { return }

            Task {
                switch action {
                case "init":
                    await storeManager.loadProducts()
                    await storeManager.refreshEntitlements()
                case "buySevenDay":
                    await storeManager.purchaseSevenDay()
                case "buyMonthly":
                    await storeManager.purchaseMonthly()
                case "restore":
                    await storeManager.restorePurchases()
                default:
                    break
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task {
                await storeManager.loadProducts()
                await storeManager.refreshEntitlements()
            }
        }

        func didUpdatePrices(sevenDay: String, monthly: String) {
            let js = "if (window.applyIosPrices) { window.applyIosPrices(\(jsonQuote(sevenDay)), \(jsonQuote(monthly))); }"
            webView?.evaluateJavaScript(js, completionHandler: nil)
        }

        func didUpdateMembership(plan: String, updatedAtMs: Double) {
            let js = """
            try {
              localStorage.setItem('membershipPlan', \(jsonQuote(plan)));
              localStorage.setItem('membershipUpdatedAt', '\(Int64(updatedAtMs))');
              if ('\(plan)' === 'seven_day') {
                localStorage.setItem('sevenDayTrackedStart', '\(Int64(updatedAtMs))');
              } else {
                localStorage.removeItem('sevenDayTrackedStart');
              }
              window.dispatchEvent(new Event('membershipChanged'));
            } catch(e) {}
            """
            webView?.evaluateJavaScript(js, completionHandler: nil)
        }

        func didReceiveNotice(title: String, message: String) {
            let js = "if (window.notifyIosToast) { window.notifyIosToast(\(jsonQuote(title)), \(jsonQuote(message))); }"
            webView?.evaluateJavaScript(js, completionHandler: nil)
        }

        private func jsonQuote(_ value: String) -> String {
            if let data = try? JSONEncoder().encode(value),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return "\"\""
        }
    }
}
