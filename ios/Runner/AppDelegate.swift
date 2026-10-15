import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let registry = engineBridge.pluginRegistry
    if let r = registry.registrar(forPlugin: "Wenku8BridgePlugin") { Wenku8BridgePlugin.register(with: r) }
    if let r = registry.registrar(forPlugin: "LocalToolsPlugin") { LocalToolsPlugin.register(with: r) }
    if let r = registry.registrar(forPlugin: "SystemSpeechPlugin") { SystemSpeechPlugin.register(with: r) }
    if let r = registry.registrar(forPlugin: "AppUpdatePlugin") { AppUpdatePlugin.register(with: r) }
  }
}
