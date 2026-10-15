import AVFoundation
import CryptoKit
import Flutter
import Security
import UIKit
import UniformTypeIdentifiers

// MARK: - Shared helpers

private enum WenkuError {
  static let legacy = FlutterError(code: "LEGACY_API_ERROR", message: "Request or local storage failed", details: nil)
}

private func postToMain(_ action: @escaping () -> Void) {
  DispatchQueue.main.async(execute: action)
}

private func rootViewController() -> UIViewController? {
  let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
  for scene in scenes {
    if let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController {
      return root
    }
  }
  return scenes.first?.windows.first?.rootViewController
}

// MARK: - legacy_api: Wenku8 relay bridge

/// Mirrors the Android Wenku8Bridge: the same relay protocol, cookie custody and
/// illustration cache. Account cookies never cross into Dart.
final class Wenku8BridgePlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "org.mewx.wenku8/legacy_api", binaryMessenger: registrar.messenger())
    let instance = Wenku8BridgePlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  private let io = DispatchQueue(label: "wenku8.api.io", attributes: .concurrent)
  private let ioSlots = DispatchSemaphore(value: 4)
  private let accounts = DispatchQueue(label: "wenku8.api.accounts")
  private let imageIo = DispatchQueue(label: "wenku8.api.images")
  private let store = AccountSessionStore()
  private var sessionCookie: String?
  private var sessionLoaded = false
  private var sessionRevision = 0
  private lazy var images: URL = {
    let root = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
    return root.appendingPathComponent("wenku8-illustrations-v1", isDirectory: true)
  }()

  private struct RelayResponse {
    let bytes: Data
    let cookie: String?
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let known: Set<String> = ["request", "cover", "requestBytes", "accountRequest", "login",
                              "hasSession", "clearSession", "illustration", "clearIllustrations", "encodeReview"]
    guard known.contains(call.method) else {
      result(FlutterMethodNotImplemented)
      return
    }
    let isAccount = ["accountRequest", "login", "hasSession", "clearSession"].contains(call.method)
    let queuedRevision = sessionRevision
    let work = { [self] in
      do {
        if isAccount && !sessionLoaded {
          sessionCookie = store.read()
          sessionLoaded = true
        }
        let args = call.arguments as? [String: Any]
        let response: Any?
        switch call.method {
        case "hasSession":
          response = sessionCookie != nil
        case "clearSession":
          store.write(nil)
          sessionCookie = nil
          sessionRevision += 1
          response = nil
        case "encodeReview":
          guard let text = args?["text"] as? String, text.count <= 10000 else { throw WenkuFailure.input }
          response = try encodeReview(text)
        case "illustration":
          response = try FlutterStandardTypedData(bytes: illustration(args?["url"] as? String ?? ""))
        case "clearIllustrations":
          if FileManager.default.fileExists(atPath: images.path) {
            try FileManager.default.removeItem(at: images)
          }
          response = nil
        default:
          let action: String
          if call.method == "cover" {
            let id = (args?["aid"] as? Int) ?? 0
            guard id > 0 else { throw WenkuFailure.input }
            action = "action=book&do=cover&aid=\(id)"
          } else {
            action = args?["action"] as? String ?? ""
          }
          guard !action.trimmingCharacters(in: .whitespaces).isEmpty, action.count <= 60000 else { throw WenkuFailure.input }
          if call.method == "login" {
            guard action.hasPrefix("action=login&") || action.hasPrefix("action=loginemail&") else { throw WenkuFailure.input }
            let reply = try requestRelay(action, cookie: nil)
            let text = String(decoding: reply.bytes, as: UTF8.self)
            if text.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
              guard let cookie = reply.cookie else { throw WenkuFailure.session }
              store.write(cookie)
              sessionCookie = cookie
              sessionRevision += 1
            }
            response = text
          } else if call.method == "accountRequest" {
            guard queuedRevision == sessionRevision else { throw WenkuFailure.session }
            guard let cookie = sessionCookie else {
              response = "4"
              break
            }
            let reply = try requestRelay(action, cookie: cookie)
            let text = String(decoding: reply.bytes, as: UTF8.self)
            if let rotated = reply.cookie, rotated != cookie, text.trimmingCharacters(in: .whitespacesAndNewlines) != "4" {
              store.write(rotated)
              sessionCookie = rotated
            }
            response = text
          } else {
            let reply = try requestRelay(action, cookie: nil)
            if call.method == "request" {
              response = String(decoding: reply.bytes, as: UTF8.self)
            } else {
              response = FlutterStandardTypedData(bytes: reply.bytes)
            }
          }
        }
        postToMain { result(response) }
      } catch WenkuFailure.encoding {
        postToMain { result(FlutterError(code: "REVIEW_ENCODING", message: "Characters outside the review encoding", details: nil)) }
      } catch {
        // Never expose actions, credentials or cookie-bearing errors.
        postToMain { result(WenkuError.legacy) }
      }
    }
    if isAccount {
      accounts.async(execute: work)
    } else if call.method == "illustration" || call.method == "clearIllustrations" {
      imageIo.async(execute: work)
    } else {
      io.async {
        self.ioSlots.wait()
        defer { self.ioSlots.signal() }
        work()
      }
    }
  }

  private enum WenkuFailure: Error {
    case input, session, encoding, network
  }

  /// appver matches the Android v1.30 runtime: HMAC-SHA256 over
  /// "<version>|<token>|<unix minute>", hex slice 12..<20.
  private func magicVersion() -> String {
    let version = "1.30"
    let token = "digital-bento"
    let minute = Int(Date().timeIntervalSince1970) / 60
    let message = "\(version)|\(token)|\(minute)"
    let digest = HMAC<SHA256>.authenticationCode(for: Array(message.utf8), using: SymmetricKey(data: Array(token.utf8)))
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    let start = hex.index(hex.startIndex, offsetBy: 12)
    let end = hex.index(start, offsetBy: 8)
    return "\(version)-\(token)-\(hex[start..<end])"
  }

  private func requestRelay(_ action: String, cookie: String?) throws -> RelayResponse {
    let encoded = Data(action.utf8).base64EncodedString()
    let body = "&appver=\(magicVersion())&request=\(encoded)&timetoken=\(Int(Date().timeIntervalSince1970 * 1000))"
    var request = URLRequest(url: URL(string: "https://wenku8-relay.mewx.org/")!)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
    if let cookie {
      request.setValue("PHPSESSID=\(cookie)", forHTTPHeaderField: "Cookie")
    }
    request.timeoutInterval = 10
    request.httpShouldHandleCookies = false
    request.httpBody = Data(body.utf8)

    let semaphore = DispatchSemaphore(value: 0)
    var outcome: Result<(Data, HTTPURLResponse), Error> = .failure(WenkuFailure.network)
    let task = URLSession.shared.dataTask(with: request) { data, response, error in
      defer { semaphore.signal() }
      if let error { outcome = .failure(error); return }
      guard let http = response as? HTTPURLResponse, let data else { return }
      outcome = .success((data, http))
    }
    task.resume()
    if semaphore.wait(timeout: .now() + 15) == .timedOut {
      task.cancel()
      throw WenkuFailure.network
    }
    let (data, http) = try outcome.get()
    guard (200..<300).contains(http.statusCode), data.count <= 8 * 1024 * 1024 else { throw WenkuFailure.network }
    let rotated = http.allHeaderFields
      .filter { ($0.key as? String)?.caseInsensitiveCompare("Set-Cookie") == .orderedSame }
      .compactMap { $0.value as? String }
      .compactMap { header -> String? in
        guard let match = try? NSRegularExpression(pattern: "(?:^|[;,]\\s*)PHPSESSID=([A-Za-z0-9,-]{8,256})")
          .firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
          let range = Range(match.range(at: 1), in: header) else { return nil }
        return String(header[range])
      }
      .first
    return RelayResponse(bytes: data, cookie: rotated)
  }

  /// GBK form encoding identical to Java URLEncoder, then base64 of the ASCII text.
  private func encodeReview(_ text: String) throws -> String {
    let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    guard let bytes = text.data(using: gbk) else { throw WenkuFailure.encoding }
    var encoded = ""
    for byte in bytes {
      switch byte {
      case UInt8(ascii: "a")...UInt8(ascii: "z"),
           UInt8(ascii: "A")...UInt8(ascii: "Z"),
           UInt8(ascii: "0")...UInt8(ascii: "9"),
           UInt8(ascii: "."), UInt8(ascii: "-"), UInt8(ascii: "*"), UInt8(ascii: "_"):
        encoded.append(Character(UnicodeScalar(byte)))
      case UInt8(ascii: " "):
        encoded.append("+")
      default:
        encoded.append(String(format: "%%%02X", byte))
      }
    }
    return Data(encoded.utf8).base64EncodedString()
  }

  private func illustration(_ raw: String) throws -> Data {
    guard let url = URL(string: raw),
          url.scheme == "https",
          url.user == nil,
          let host = url.host,
          host == "wenku8.com" || host.hasSuffix(".wenku8.com") ||
          host == "wenku8.net" || host.hasSuffix(".wenku8.net") else {
      throw WenkuFailure.input
    }
    let name = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    let file = images.appendingPathComponent(name)
    let manager = FileManager.default
    if manager.fileExists(atPath: file.path),
       let cached = try? Data(contentsOf: file),
       !cached.isEmpty, cached.count <= 8 * 1024 * 1024,
       validImage(cached) {
      try? manager.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
      return cached
    }
    try? manager.removeItem(at: file)

    var request = URLRequest(url: url)
    request.timeoutInterval = 12
    request.httpShouldHandleCookies = false
    let semaphore = DispatchSemaphore(value: 0)
    var outcome: Result<Data, Error> = .failure(WenkuFailure.network)
    let task = URLSession.shared.dataTask(with: request) { data, response, error in
      defer { semaphore.signal() }
      if let error { outcome = .failure(error); return }
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
            let data, data.count <= 8 * 1024 * 1024 else { return }
      outcome = .success(data)
    }
    task.resume()
    if semaphore.wait(timeout: .now() + 20) == .timedOut {
      task.cancel()
      throw WenkuFailure.network
    }
    let bytes = try outcome.get()
    guard validImage(bytes) else { throw WenkuFailure.input }
    // An online illustration survives a cache write error.
    if let _ = try? manager.createDirectory(at: images, withIntermediateDirectories: true) {
      let temporary = images.appendingPathComponent("\(name).part")
      if let _ = try? bytes.write(to: temporary, options: .atomic) {
        try? manager.removeItem(at: file)
        try? manager.moveItem(at: temporary, to: file)
        trimImageCache(keeping: file)
      }
    }
    return bytes
  }

  private func trimImageCache(keeping current: URL) {
    let manager = FileManager.default
    guard let entries = try? manager.contentsOfDirectory(
      at: images,
      includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
    ) else { return }
    var total = Int64(0)
    var dated: [(URL, Date, Int64)] = []
    for entry in entries {
      guard let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
            let size = values.fileSize, size > 0 else { continue }
      total += Int64(size)
      dated.append((entry, values.contentModificationDate ?? .distantPast, Int64(size)))
    }
    for (url, _, size) in dated.sorted(by: { $0.1 < $1.1 }) {
      if total <= 256 * 1024 * 1024 { break }
      if url != current, (try? manager.removeItem(at: url)) != nil { total -= size }
    }
  }

  private func validImage(_ bytes: Data) -> Bool {
    guard let image = UIImage(data: bytes) else { return false }
    let width = image.size.width * image.scale
    let height = image.size.height * image.scale
    return width > 0 && height > 0 && width * height <= 50_000_000
  }
}

// MARK: - legacy_api: Keychain session custody

/// Device-bound session only: no password, export, log or cloud sync.
final class AccountSessionStore {
  private let service = "wenku8.account.session.v1"
  private let account = "session"
  private let pattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9,-]{8,256}$")

  private func valid(_ value: String) -> Bool {
    pattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
  }

  func read() -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data,
          let value = String(data: data, encoding: .utf8),
          valid(value) else { return nil }
    return value
  }

  func write(_ cookie: String?) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
    guard let cookie, valid(cookie), let data = cookie.data(using: .utf8) else { return }
    var attributes = query
    attributes[kSecValueData as String] = data
    attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    SecItemAdd(attributes as CFDictionary, nil)
  }
}

// MARK: - local_tools: documents, share, screen

/// Explicit document/share actions; never touches the Wenku8 bridge/session.
final class LocalToolsPlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "org.mewx.wenku8/local_tools", binaryMessenger: registrar.messenger())
    let instance = LocalToolsPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  private static let maxBytes = 4 * 1024 * 1024
  private var pickerActive = false
  private var pickerDelegate: Any?

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getKeepScreenOn":
      result(UIApplication.shared.isIdleTimerDisabled)
    case "keepScreenOn":
      DispatchQueue.main.async {
        UIApplication.shared.isIdleTimerDisabled = (call.arguments as? Bool) == true
        result(nil)
      }
    case "shareText":
      let text = (call.arguments as? [String: Any])?["text"] as? String ?? ""
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 10000 else {
        result(FlutterError(code: "input", message: "Invalid share text", details: nil))
        return
      }
      DispatchQueue.main.async {
        guard let controller = rootViewController() else {
          result(FlutterError(code: "share", message: "Share sheet did not open", details: nil))
          return
        }
        let sheet = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
          popover.sourceView = controller.view
          popover.sourceRect = CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.midY, width: 0, height: 0)
          popover.permittedArrowDirections = []
        }
        controller.present(sheet, animated: true)
        result(nil)
      }
    case "exportBackup":
      let args = call.arguments as? [String: Any]
      guard let text = args?["text"] as? String, text.utf8.count <= Self.maxBytes else {
        result(FlutterError(code: "size", message: "Backup exceeds the document limit", details: nil))
        return
      }
      let name = args?["name"] as? String ?? "wenku8-backup.json"
      guard !pickerActive else {
        result(FlutterError(code: "busy", message: "A document operation is already active", details: nil))
        return
      }
      pickerActive = true
      let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(name)
      do {
        try text.write(to: temporary, atomically: true, encoding: .utf8)
      } catch {
        result(FlutterError(code: "document", message: "Document read or write failed", details: nil))
        return
      }
      presentPicker(exporting: [temporary]) { outcome in
        defer { try? FileManager.default.removeItem(at: temporary) }
        outcome == true ? result(true) : result(false)
      }
    case "importBackup":
      guard !pickerActive else {
        result(FlutterError(code: "busy", message: "A document operation is already active", details: nil))
        return
      }
      guard #available(iOS 14.0, *) else {
        result(FlutterError(code: "picker", message: "Document picker could not open", details: nil))
        return
      }
      pickerActive = true
      presentPicker(opening: [.json, .plainText, .data]) { url in
        guard let url else { result(nil); return }
        do {
          let data = try Data(contentsOf: url)
          guard data.count <= Self.maxBytes, let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
          }
          result(text)
        } catch {
          result(FlutterError(code: "document", message: "Document read or write failed", details: nil))
        }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func presentPicker(exporting urls: [URL], completion: @escaping (Bool?) -> Void) {
    DispatchQueue.main.async {
      guard #available(iOS 14.0, *) else {
        pickerActive = false
        completion(nil)
        return
      }
      guard let controller = rootViewController() else {
        pickerActive = false
        completion(nil)
        return
      }
      let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
      let delegate = ExportDelegate { [weak self] ok in
        self?.pickerActive = false
        self?.pickerDelegate = nil
        completion(ok)
      }
      picker.delegate = delegate
      pickerDelegate = delegate
      controller.present(picker, animated: true)
    }
  }

  private func presentPicker(opening types: [UTType], completion: @escaping (URL?) -> Void) {
    DispatchQueue.main.async {
      guard #available(iOS 14.0, *) else {
        pickerActive = false
        completion(nil)
        return
      }
      guard let controller = rootViewController() else {
        pickerActive = false
        completion(nil)
        return
      }
      let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
      let delegate = ImportDelegate { [weak self] url in
        self?.pickerActive = false
        self?.pickerDelegate = nil
        completion(url)
      }
      picker.delegate = delegate
      pickerDelegate = delegate
      controller.present(picker, animated: true)
    }
  }

  private final class ExportDelegate: NSObject, UIDocumentPickerDelegate {
    init(_ done: @escaping (Bool?) -> Void) { self.done = done }
    let done: (Bool?) -> Void
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { done(true) }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { done(false) }
  }

  private final class ImportDelegate: NSObject, UIDocumentPickerDelegate {
    init(_ done: @escaping (URL?) -> Void) { self.done = done }
    let done: (URL?) -> Void
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { done(urls.first) }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { done(nil) }
  }
}

// MARK: - system_speech: AVSpeechSynthesizer file synthesis

/// Public Apple speech synthesis only. File synthesis never plays sound.
final class SystemSpeechPlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "org.mewx.wenku8/system_speech", binaryMessenger: registrar.messenger())
    let instance = SystemSpeechPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  static let engineId = "apple"
  private let synthesizer = AVSpeechSynthesizer()
  private var pendingId: String?
  private var pendingResult: FlutterResult?
  private var pendingTarget: URL?

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "engines":
      result([["id": Self.engineId, "name": "Apple 系统语音"]])
    case "voices":
      guard args?["engine"] as? String == Self.engineId else {
        result(FlutterError(code: "TTS_ENGINE", message: "请选择受支持的系统语音引擎", details: nil))
        return
      }
      let voices = AVSpeechSynthesisVoice.speechVoices()
        .filter { $0.language.hasPrefix("zh") }
        .map { voice -> [String: Any] in
          let language = voice.language == "zh" ? "zh-CN" : voice.language
          return [
            "id": voice.identifier,
            "locale": language,
            "quality": voice.quality.rawValue,
            "latency": 0,
            "networkRequired": false,
            "features": [String](),
          ]
        }
      result(voices)
    case "settings":
      if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url)
      }
      result(nil)
    case "synthesize":
      synthesize(call, result: result)
    case "cancel":
      if let id = args?["requestId"] as? String, id == pendingId {
        synthesizer.stopSpeaking(at: .immediate)
        finish(error: ("TTS_CANCELLED", "合成已取消"))
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func synthesize(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    let requestId = args?["requestId"] as? String ?? ""
    let text = args?["text"] as? String ?? ""
    let voiceId = args?["voice"] as? String ?? ""
    let path = args?["path"] as? String ?? ""
    let target = URL(fileURLWithPath: path).standardizedFileURL
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!.standardizedFileURL
    let idValid = requestId.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil
    let nameValid = target.lastPathComponent.range(of: "^[a-f0-9]{64}\\.wav\\.part$", options: .regularExpression) != nil
    guard idValid,
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          text.count <= 3500,
          nameValid,
          target.deletingLastPathComponent().path.hasPrefix(caches.path) else {
      result(FlutterError(code: "TTS_INPUT", message: "语音文本或缓存位置无效", details: nil))
      return
    }
    guard pendingId == nil else {
      result(FlutterError(code: "TTS_BUSY", message: "系统语音正在准备上一段", details: nil))
      return
    }
    guard let voice = AVSpeechSynthesisVoice(identifier: voiceId) ?? AVSpeechSynthesisVoice(language: "zh-CN") else {
      result(FlutterError(code: "TTS_VOICE", message: "该系统音色暂未就绪", details: nil))
      return
    }
    pendingId = requestId
    pendingResult = result
    pendingTarget = target

    DispatchQueue.global(qos: .userInitiated).async { [self] in
      do {
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try AVAudioSession.sharedInstance().setActive(true)
        let wav = target.deletingPathExtension().appendingPathExtension("wav")
        try? FileManager.default.removeItem(at: wav)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        var output: AVAudioFile?
        var failed = false
        let done = DispatchSemaphore(value: 0)
        synthesizer.write(utterance) { buffer in
          guard let pcm = buffer as? AVAudioPCMBuffer else {
            done.signal()
            return
          }
          if pcm.frameLength == 0 { done.signal(); return }
          do {
            if output == nil {
              let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: pcm.format.sampleRate,
                AVNumberOfChannelsKey: pcm.format.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
              ]
              output = try AVAudioFile(forWriting: wav, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            }
            try output?.write(from: pcm)
          } catch {
            failed = true
          }
        }
        if done.wait(timeout: .now() + 35) == .timedOut {
          synthesizer.stopSpeaking(at: .immediate)
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        DispatchQueue.main.async { [self] in
          guard !failed, let file = output, file.length > 45 else {
            try? FileManager.default.removeItem(at: wav)
            finish(error: ("TTS_CONTENT", "系统语音没有生成有效音频"))
            return
          }
          do {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: wav, to: target)
            finish(success: target.path)
          } catch {
            finish(error: ("TTS_SYNTH", "离线语音合成失败，请重试"))
          }
        }
      } catch {
        DispatchQueue.main.async { [self] in
          finish(error: ("TTS_SYNTH", "离线语音合成失败，请重试"))
        }
      }
    }
  }

  private func finish(success: String) {
    pendingResult?(success)
    clear()
  }

  private func finish(error: (String, String)) {
    pendingResult?(FlutterError(code: error.0, message: error.1, details: nil))
    clear()
  }

  private func clear() {
    if let target = pendingTarget { try? FileManager.default.removeItem(at: target.deletingPathExtension().appendingPathExtension("wav")) }
    pendingId = nil
    pendingResult = nil
    pendingTarget = nil
  }
}

// MARK: - app_updates: version info and release page

/// iOS cannot self-install packages; the channel reports versions and opens the
/// GitHub release page so users can re-sign a newer IPA themselves.
final class AppUpdatePlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "org.mewx.wenku8/app_updates", binaryMessenger: registrar.messenger())
    let instance = AppUpdatePlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "info":
      let info = Bundle.main.infoDictionary
      let version = info?["CFBundleShortVersionString"] as? String ?? "0"
      let build = Int(info?["CFBundleVersion"] as? String ?? "0") ?? 0
      result(["version": version, "build": build, "abis": ["arm64"]])
    case "openRelease":
      guard let raw = call.arguments as? String,
            let url = URL(string: raw),
            url.scheme == "https",
            url.host == "github.com",
            url.user == nil,
            url.path.contains("/releases/") else {
        result(FlutterError(code: "OPEN", message: "系统页面无法打开，请重试", details: nil))
        return
      }
      DispatchQueue.main.async {
        UIApplication.shared.open(url) { ok in
          ok ? result(nil) : result(FlutterError(code: "OPEN", message: "系统页面无法打开，请重试", details: nil))
        }
      }
    case "allowInstalls":
      result(nil)
    case "install":
      result(FlutterError(code: "APK_REJECTED", message: "iOS 请在 Releases 页面下载 IPA 后重新自签安装", details: nil))
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
