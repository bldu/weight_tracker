import Cocoa
import CFNetwork
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    let proxyChannel = FlutterMethodChannel(
      name: "weight_tracker/proxy",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    proxyChannel.setMethodCallHandler { call, result in
      guard call.method == "getSystemProxy" else {
        result(FlutterMethodNotImplemented)
        return
      }

      guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
        result(nil)
        return
      }

      let payload: [String: Any] = [
        "httpEnabled": (settings[kCFNetworkProxiesHTTPEnable as String] as? NSNumber)?.boolValue ?? false,
        "httpHost": settings[kCFNetworkProxiesHTTPProxy as String] as? String ?? "",
        "httpPort": (settings[kCFNetworkProxiesHTTPPort as String] as? NSNumber)?.intValue ?? 0,
        "httpsEnabled": (settings[kCFNetworkProxiesHTTPSEnable as String] as? NSNumber)?.boolValue ?? false,
        "httpsHost": settings[kCFNetworkProxiesHTTPSProxy as String] as? String ?? "",
        "httpsPort": (settings[kCFNetworkProxiesHTTPSPort as String] as? NSNumber)?.intValue ?? 0,
        "exceptions": settings[kCFNetworkProxiesExceptionsList as String] as? [String] ?? []
      ]

      result(payload)
    }

    super.awakeFromNib()
  }
}
