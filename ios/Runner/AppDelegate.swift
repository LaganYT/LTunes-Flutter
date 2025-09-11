import Flutter
import UIKit
import UserNotifications
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let bluetoothChannelName = "bluetooth_events"
  private var bluetoothChannel: FlutterMethodChannel?
  private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    
    // Set notification delegate for iOS 10+
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    }
    
    // Configure audio session for background playback with comprehensive options
    do {
      let audioSession: AVAudioSession = AVAudioSession.sharedInstance()
      // Enhanced category options for better background playback
      try audioSession.setCategory(.playback, 
                                 mode: .default, 
                                 options: [.allowBluetooth, 
                                          .allowBluetoothA2DP, 
                                          .allowAirPlay,
                                          .mixWithOthers])
      try audioSession.setActive(true, options: [])
      print("iOS audio session configured for background playback on app launch")
      
      // Add notification observer for route changes
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(handleRouteChange),
        name: AVAudioSession.routeChangeNotification,
        object: nil
      )
      
      // Add notification observer for interruptions
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(handleInterruption),
        name: AVAudioSession.interruptionNotification,
        object: nil
      )
      
      // Add observer for audio session media services lost (when session becomes inactive)
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(handleMediaServicesLost),
        name: AVAudioSession.mediaServicesWereLostNotification,
        object: nil
      )
      
      // Add observer for audio session media services reset
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(handleMediaServicesReset),
        name: AVAudioSession.mediaServicesWereResetNotification,
        object: nil
      )
    } catch {
      print("Error configuring iOS audio session on app launch: \(error)")
    }
    
    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    guard let controller = window?.rootViewController as? FlutterViewController else {
      return result
    }
    bluetoothChannel = FlutterMethodChannel(name: bluetoothChannelName, binaryMessenger: controller.binaryMessenger)
    return result
  }
  
  // MARK: - UNUserNotificationCenterDelegate
  @available(iOS 10.0, *)
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    // Show notification even when app is in foreground
    completionHandler([.alert, .badge, .sound])
  }
  
  // MARK: - Audio Session Route Change Handling
  @objc func handleRouteChange(notification: Notification) {
    guard let userInfo = notification.userInfo,
          let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
          let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
      return
    }
    
    switch reason {
    case .newDeviceAvailable:
      print("New audio device available")
      bluetoothChannel?.invokeMethod("bluetooth_connected", arguments: nil)
      // Pause playback when headphones are unplugged
      // This will be handled by the Flutter audio handler
    case .oldDeviceUnavailable:
      print("Audio device unavailable")
      bluetoothChannel?.invokeMethod("bluetooth_disconnected", arguments: nil)
      // Pause playback when headphones are unplugged
      // This will be handled by the Flutter audio handler
    default:
      break
    }
  }
  
  // MARK: - Audio Session Interruption Handling
  @objc func handleInterruption(notification: Notification) {
    guard let userInfo = notification.userInfo,
          let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
      return
    }
    
    switch type {
    case .began:
      print("Audio session interruption began")
    case .ended:
      print("Audio session interruption ended")
      // Reactivate the audio session when interruption ends
      do {
        let audioSession: AVAudioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playback, 
                                   mode: .default, 
                                   options: [.allowBluetooth, 
                                            .allowBluetoothA2DP, 
                                            .allowAirPlay,
                                            .mixWithOthers])
        try audioSession.setActive(true, options: [])
        print("iOS audio session reactivated after interruption with full configuration")
      } catch {
        print("Error reactivating iOS audio session after interruption: \(error)")
      }
    @unknown default:
      break
    }
  }
  
  // MARK: - Audio Session Media Services Handling
  @objc func handleMediaServicesLost(notification: Notification) {
    print("iOS audio media services were lost - attempting to recover")
    // When media services are lost, the audio session becomes inactive
    // We need to prepare for recovery when services are restored
  }
  
  @objc func handleMediaServicesReset(notification: Notification) {
    print("iOS audio media services were reset - reconfiguring audio session")
    // When services are reset, we need to reconfigure the entire audio session
    do {
      let audioSession: AVAudioSession = AVAudioSession.sharedInstance()
      try audioSession.setCategory(.playback, 
                                 mode: .default, 
                                 options: [.allowBluetooth, 
                                          .allowBluetoothA2DP, 
                                          .allowAirPlay,
                                          .mixWithOthers])
      try audioSession.setActive(true, options: [])
      print("iOS audio session reconfigured after media services reset")
    } catch {
      print("Error reconfiguring iOS audio session after media services reset: \(error)")
    }
  }
  
  @available(iOS 10.0, *)
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    // Handle notification tap
    completionHandler()
  }
  
  // Handle app entering background
  override func applicationDidEnterBackground(_ application: UIApplication) {
    super.applicationDidEnterBackground(application)
    
    // Start background task to maintain audio session
    startBackgroundTask()
    
    // Ensure audio session is properly configured for background playback
    do {
      let audioSession: AVAudioSession = AVAudioSession.sharedInstance()
      try audioSession.setCategory(.playback, 
                                 mode: .default, 
                                 options: [.allowBluetooth, 
                                          .allowBluetoothA2DP, 
                                          .allowAirPlay,
                                          .mixWithOthers])
      try audioSession.setActive(true, options: [])
      print("iOS audio session configured for background playback with enhanced options")
      
      // For better background audio persistence, set the session to not deactivate
      try audioSession.setActive(true, options: [])
      print("iOS audio session set to persist in background")
      
      // Add a timer to periodically maintain the audio session
      DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
        do {
          try audioSession.setActive(true)
          print("iOS background session maintenance: 5 second check")
        } catch {
          print("Error in iOS background session maintenance: \(error)")
        }
      }
      
      // Add another check after 15 seconds
      DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) {
        do {
          try audioSession.setActive(true)
          print("iOS background session maintenance: 15 second check")
        } catch {
          print("Error in iOS background session maintenance: \(error)")
        }
      }
      
      // Add more frequent checks for queue looping continuity
      for i in 1...6 {
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(i * 10)) {
          do {
            try audioSession.setActive(true)
            print("iOS background session maintenance: \(i * 10) second check for queue looping")
          } catch {
            print("Error in iOS background session maintenance for queue looping: \(error)")
          }
        }
      }
      
      // Add a final check after 2 minutes to ensure long-term background playback
      DispatchQueue.main.asyncAfter(deadline: .now() + 120.0) {
        do {
          try audioSession.setActive(true)
          print("iOS background session maintenance: 2 minute check for long-term background playback")
        } catch {
          print("Error in iOS background session maintenance for long-term background playback: \(error)")
        }
      }
    } catch {
      print("Error configuring iOS audio session for background: \(error)")
    }
  }
  
  // Handle app entering foreground
  override func applicationWillEnterForeground(_ application: UIApplication) {
    super.applicationWillEnterForeground(application)
    
    // End background task as we're now in foreground
    endBackgroundTask()
    
    // Reactivate audio session when app comes to foreground
    do {
      let audioSession: AVAudioSession = AVAudioSession.sharedInstance()
      try audioSession.setCategory(.playback, 
                                 mode: .default, 
                                 options: [.allowBluetooth, 
                                          .allowBluetoothA2DP, 
                                          .allowAirPlay,
                                          .mixWithOthers])
      try audioSession.setActive(true, options: [])
      print("iOS audio session reactivated for foreground with enhanced configuration")
      
      // If we were playing audio in background, ensure it continues seamlessly
      if audioSession.isOtherAudioPlaying {
        print("iOS: Other audio detected, maintaining playback session")
      }
    } catch {
      print("Error reactivating iOS audio session: \(error)")
    }
  }
  
  // Handle app about to be suspended (additional background audio session maintenance)
  override func applicationWillResignActive(_ application: UIApplication) {
    super.applicationWillResignActive(application)
    
    // Ensure audio session is maintained when app is about to be suspended
    do {
      let audioSession: AVAudioSession = AVAudioSession.sharedInstance()
      try audioSession.setCategory(.playback, 
                                 mode: .default, 
                                 options: [.allowBluetooth, 
                                          .allowBluetoothA2DP, 
                                          .allowAirPlay,
                                          .mixWithOthers])
      try audioSession.setActive(true, options: [])
      print("iOS audio session maintained for app suspension with enhanced configuration")
    } catch {
      print("Error maintaining iOS audio session for suspension: \(error)")
    }
  }
  
  // MARK: - Background Task Management
  private func startBackgroundTask() {
    guard backgroundTaskId == .invalid else { return }
    
    backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "AudioSessionMaintenance") { [weak self] in
      self?.endBackgroundTask()
    }
    
    print("Started background task for audio session maintenance: \(backgroundTaskId)")
  }
  
  private func endBackgroundTask() {
    guard backgroundTaskId != .invalid else { return }
    
    print("Ending background task: \(backgroundTaskId)")
    UIApplication.shared.endBackgroundTask(backgroundTaskId)
    backgroundTaskId = .invalid
  }
  
  deinit {
    endBackgroundTask()
    NotificationCenter.default.removeObserver(self)
  }
}
