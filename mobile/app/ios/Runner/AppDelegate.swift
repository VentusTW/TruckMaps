import AVFoundation
import UIKit
import Flutter

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
  // Głos nawigacji (kanał `truckmaps/speech`, jak `MainActivity` na Androidzie): syntezator
  // systemu bez sieci; nowy komunikat przerywa poprzedni.
  private let synthesizer = AVSpeechSynthesizer()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(name: "truckmaps/speech", binaryMessenger: controller.binaryMessenger)
      channel.setMethodCallHandler { [weak self] call, result in
        self?.handleSpeech(call, result: result)
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func handleSpeech(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "speak":
      guard let arguments = call.arguments as? [String: Any], let text = arguments["text"] as? String else {
        result(FlutterError(code: "args", message: "text required", details: nil))
        return
      }
      // Mowa także przy wyciszonym dzwonku i ściszenie innej muzyki na czas komunikatu.
      try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
      try? AVAudioSession.sharedInstance().setActive(true)
      synthesizer.stopSpeaking(at: .immediate)
      let utterance = AVSpeechUtterance(string: text)
      if let language = arguments["language"] as? String, let voice = AVSpeechSynthesisVoice(language: language) {
        utterance.voice = voice
      }
      synthesizer.speak(utterance)
      result(nil)
    case "stop":
      synthesizer.stopSpeaking(at: .immediate)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
