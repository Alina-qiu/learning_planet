import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let parentPush = ParentPush()
  private let nativeDiagnostics = NativeDiagnostics()
  private lazy var taskNotifications = TaskNotificationDelegate(forward: self)
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Register before any Flutter engine is needed. Flutter forwards this
    // optional UIApplication callback dynamically through lifecycle delegates.
    addApplicationLifeCycleDelegate(parentPush)
    nativeDiagnostics.start()
    UNUserNotificationCenter.current().delegate = taskNotifications
    // A terminated document picker can leave its staging ZIP behind. Only our
    // export filenames are eligible; unrelated temporary imports are retained.
    try? Self.purgeExportTemporaryFiles()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let diagnosticChannel = FlutterMethodChannel(name: "learning_planet/native_diagnostics",
      binaryMessenger: engineBridge.applicationRegistrar.messenger())
    diagnosticChannel.setMethodCallHandler { [weak self] call, result in
      self?.nativeDiagnostics.handle(call, result: result)
    }
    let pushChannel = FlutterMethodChannel(name: "learning_planet/parent_push",
      binaryMessenger: engineBridge.applicationRegistrar.messenger())
    pushChannel.setMethodCallHandler { [weak self] call, result in
      self?.parentPush.handle(call, result: result)
    }
    let exportChannel = FlutterMethodChannel(
      name: "learning_planet/export_temporary_files",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    exportChannel.setMethodCallHandler { call, result in
      guard call.method == "purge" else {
        result(FlutterMethodNotImplemented)
        return
      }
      do {
        try Self.purgeExportTemporaryFiles()
        result(nil)
      } catch {
        result(FlutterError(code: "export_cleanup_failed", message: "导出临时文件清理失败", details: nil))
      }
    }
    let protectionChannel = FlutterMethodChannel(
      name: "learning_planet/local_file_protection",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    protectionChannel.setMethodCallHandler { call, result in
      guard call.method == "protect",
        let arguments = call.arguments as? [String: Any],
        let path = arguments["path"] as? String else {
        result(FlutterMethodNotImplemented)
        return
      }
      do {
        try Self.protectLocalFiles(path: path)
        result(nil)
      } catch {
        result(FlutterError(code: "local_protection_failed", message: "本机文件保护未能启用", details: nil))
      }
    }
  }

  private static func protectLocalFiles(path: String) throws {
    let manager = FileManager.default
    var directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    let expected = try manager.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true
    ).standardizedFileURL
    // Restrict this method to our own Application Support directory.
    guard directory.resolvingSymlinksInPath().path == expected.resolvingSymlinksInPath().path else {
      throw NSError(domain: "LocalFileProtection", code: 1)
    }
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try directory.setResourceValues(values)
    try manager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
    // New database/sidecar files inherit the directory protection. Apply it
    // explicitly to existing database and interrupted migration files too.
    let prefixes = ["learning_planet.sqlite", "learning_planet.encrypted.sqlite"]
    for file in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
      guard prefixes.contains(where: { file.lastPathComponent == $0 || file.lastPathComponent.hasPrefix($0 + "-") || file.lastPathComponent.hasPrefix($0 + ".") }) else { continue }
      guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
        throw NSError(domain: "LocalFileProtection", code: 2)
      }
      try manager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: file.path)
    }
  }

  private static func purgeExportTemporaryFiles() throws {
    let manager = FileManager.default
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    let uuid = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
    let pattern = "^learning-planet-\(uuid)-\(uuid)\\.zip$"
    let files = try manager.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
    )
    for file in files where file.lastPathComponent.range(of: pattern, options: .regularExpression) != nil {
      let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      if values.isRegularFile == true && values.isSymbolicLink != true {
        try manager.removeItem(at: file)
      }
    }
  }
}

// iOS exposes this callback only while the application is in the foreground.
// Background local presentation remains owned by the operating system.
private final class TaskNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
  private weak var forward: UNUserNotificationCenterDelegate?
  init(forward: UNUserNotificationCenterDelegate) {
    self.forward = forward
    super.init()
  }
  func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    let content = notification.request.content
    let text = content.userInfo["payload"] as? String
    let data = text?.data(using: .utf8)
    let payload = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    let task = content.threadIdentifier == "learning_tasks" || (payload?["child"] != nil && payload?["key"] != nil)
    if task && !Self.allowed(payload) { completionHandler([]); return }
    let selector = #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:))
    if let delegate = forward, delegate.responds(to: selector) {
      delegate.userNotificationCenter?(center, willPresent: notification, withCompletionHandler: completionHandler)
    } else { completionHandler([]) }
  }
  private static func allowed(_ row: [String: Any]?) -> Bool {
    guard let row = row, row["kind"] as? String == "task-reminder-v1",
      let at = row["at"] as? NSNumber, let name = row["timezone"] as? String,
      let zone = TimeZone(identifier: name), let start = row["quiet_start"] as? String,
      let end = row["quiet_end"] as? String else { return false }
    let pattern = "^([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]$"
    guard start.range(of: pattern, options: .regularExpression) != nil,
      end.range(of: pattern, options: .regularExpression) != nil else { return false }
    let now = Date()
    let elapsed = now.timeIntervalSince1970 * 1000 - at.doubleValue
    guard at.doubleValue.isFinite, elapsed >= 0, elapsed < 900000 else { return false }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let local = calendar.component(.hour, from: now) * 3600 + calendar.component(.minute, from: now) * 60 + calendar.component(.second, from: now)
    func seconds(_ text: String) -> Int {
      let parts = text.split(separator: ":").compactMap { Int($0) }
      return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }
    let a = seconds(start), b = seconds(end)
    return a == b || !(a < b ? local >= a && local < b : local >= a || local < b)
  }
  func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void) {
    let selector = #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:))
    if let delegate = forward, delegate.responds(to: selector) {
      delegate.userNotificationCenter?(center, didReceive: response, withCompletionHandler: completionHandler)
    } else { completionHandler() }
  }
  func userNotificationCenter(_ center: UNUserNotificationCenter, openSettingsFor notification: UNNotification?) {
    forward?.userNotificationCenter?(center, openSettingsFor: notification)
  }
}
