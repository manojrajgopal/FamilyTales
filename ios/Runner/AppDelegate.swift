import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Lets flutter_local_notifications present on-device reminders.
    UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // "family_tales/privacy": keeps the local family database out of iCloud
    // device backups, because Family Tales never uploads data automatically.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FamilyTalesPrivacy") {
      let channel = FlutterMethodChannel(
        name: "family_tales/privacy", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        switch call.method {
        case "excludeFromBackup":
          guard let args = call.arguments as? [String: Any],
                let path = args["path"] as? String else {
            result(FlutterError(code: "bad_args", message: "path missing", details: nil))
            return
          }
          var url = URL(fileURLWithPath: path)
          var values = URLResourceValues()
          values.isExcludedFromBackup = true
          do {
            try url.setResourceValues(values)
            result(true)
          } catch {
            result(FlutterError(code: "failed", message: error.localizedDescription, details: nil))
          }
        case "setSecureContent":
          // iOS hides the app-switcher snapshot via the Flutter privacy overlay.
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }
}
