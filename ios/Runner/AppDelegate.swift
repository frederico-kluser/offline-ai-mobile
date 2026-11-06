import AVFoundation
import Darwin
import Flutter
import Metal
import UIKit
import os

/// Canal nativo do perfilador de hardware (`offline_ai_mobile/hardware`).
///
/// Lê RAM física e disponível para o processo, disco livre, núcleos de
/// performance, instruções ARM (dotprod/i8mm) e Metal. O simulador iOS é
/// detetado e reportado como sem GPU (Metal incompleto no simulador).
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var hardwareChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "HardwareProfile") else {
      return
    }
    let channel = FlutterMethodChannel(
      name: "offline_ai_mobile/hardware",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "unavailable", message: "AppDelegate libertado", details: nil))
        return
      }
      switch call.method {
      case "getHardwareMetrics":
        result(self.hardwareMetrics())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    hardwareChannel = channel

    let media = FlutterMethodChannel(
      name: "offline_ai_mobile/media",
      binaryMessenger: registrar.messenger()
    )
    media.setMethodCallHandler { call, result in
      guard call.method == "extractVideoFrames" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String else {
        result(FlutterError(code: "bad-args", message: "path em falta", details: nil))
        return
      }
      let fps = (args["fps"] as? Double) ?? 2.0
      do {
        result(try self.extractVideoFrames(path: path, fps: fps))
      } catch {
        result(FlutterError(code: "video-error", message: error.localizedDescription, details: nil))
      }
    }
    mediaChannel = media
  }

  private var mediaChannel: FlutterMethodChannel?

  /// Extrai frames a `fps` para JPEG em tmp; a banda sonora não é extraída.
  private func extractVideoFrames(path: String, fps: Double) throws -> [String: Any] {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let duration = CMTimeGetSeconds(asset.duration)
    guard duration.isFinite, duration > 0 else {
      throw NSError(domain: "offline_ai_mobile", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "duração de vídeo desconhecida"])
    }
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("video_frames")
    if FileManager.default.fileExists(atPath: dir.path) {
      try? FileManager.default.removeItem(at: dir)
    }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    var frames: [String] = []
    let step = 1.0 / max(1.0, fps)
    var t = 0.0
    var i = 0
    while t < duration {
      let time = CMTime(seconds: t, preferredTimescale: 600)
      if let image = try? generator.copyCGImage(at: time, actualTime: nil) {
        let ui = UIImage(cgImage: image)
        if let data = ui.jpegData(compressionQuality: 0.85) {
          let file = dir.appendingPathComponent(String(format: "frame_%03d.jpg", i))
          try data.write(to: file)
          frames.append(file.path)
        }
      }
      t += step
      i += 1
    }
    if frames.isEmpty {
      throw NSError(domain: "offline_ai_mobile", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "sem frames extraídos"])
    }
    return [
      "frames": frames,
      "soundtrack": NSNull(),
      "fps": fps,
      "duration_ms": Int(duration * 1000),
    ]
  }

  private func hardwareMetrics() -> [String: Any] {
    let physical = ProcessInfo.processInfo.physicalMemory
    var available: UInt64 = 0
    if #available(iOS 13.0, *) {
      available = UInt64(os_proc_available_memory())
    }
    if available == 0 {
      available = physical / 2
    }

    let freeDisk = freeStorageBytes()
    let perf = performanceCores()
    let logical = ProcessInfo.processInfo.activeProcessorCount

    #if targetEnvironment(simulator)
      let simulator = true
    #else
      let simulator = false
    #endif

    let metal = MTLCreateSystemDefaultDevice() != nil && !simulator

    return [
      "totalRamMb": Int(physical / (1024 * 1024)),
      "availableRamMb": Int(available / (1024 * 1024)),
      "freeStorageMb": Int(freeDisk / (1024 * 1024)),
      "performanceCores": perf,
      "logicalCores": logical,
      "hasArmDotProd": sysctlFlag("hw.optional.arm.FEAT_DotProd"),
      "hasArmI8mm": sysctlFlag("hw.optional.arm.FEAT_I8MM"),
      "hasGpuAcceleration": metal,
      "hasMetal": metal,
      "isIosSimulator": simulator,
      "platform": "ios",
      "systemVersion": UIDevice.current.systemVersion,
    ]
  }

  private func freeStorageBytes() -> UInt64 {
    let url = URL(fileURLWithPath: NSHomeDirectory())
    guard let values = try? url.resourceValues(
      forKeys: [.volumeAvailableCapacityForImportantUsageKey]
    ) else {
      return 0
    }
    return UInt64(values.volumeAvailableCapacityForImportantUsage ?? 0)
  }

  /// `hw.perflevel0.logicalcpu` = núcleos de performance; fallback big cores.
  private func performanceCores() -> Int {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    if sysctlbyname("hw.perflevel0.logicalcpu", &value, &size, nil, 0) == 0, value > 0 {
      return Int(value)
    }
    return max(1, ProcessInfo.processInfo.activeProcessorCount - 2)
  }

  private func sysctlFlag(_ name: String) -> Bool {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    if sysctlbyname(name, &value, &size, nil, 0) == 0 {
      return value != 0
    }
    return false
  }
}
