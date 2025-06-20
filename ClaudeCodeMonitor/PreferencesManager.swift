import Foundation
import AppKit
import ServiceManagement

class PreferencesManager: ObservableObject {
    static let shared = PreferencesManager()
    
    @Published var useTemplateIcon: Bool {
        didSet {
            UserDefaults.standard.set(useTemplateIcon, forKey: "useTemplateIcon")
            NotificationCenter.default.post(name: .iconModeChanged, object: nil)
        }
    }
    
    @Published var notificationSound: String {
        didSet {
            UserDefaults.standard.set(notificationSound, forKey: "notificationSound")
        }
    }
    
    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
            updateLaunchAtLogin()
        }
    }
    
    @Published var windowHeight: CGFloat {
        didSet {
            UserDefaults.standard.set(windowHeight, forKey: "windowHeight")
        }
    }
    
    let availableSounds = [
        ("None", "None"),
        ("8-bit Powerup", "431329__someguy22__8-bit-powerup.wav"),
        ("Bosch Microwave", "689037__voxlab__beep-tone-of-our-microwave-bosch.wav"),
        ("Ceramic Mug", "807780__designerschoice__foodgware-blue-snowball-microphone-cu_ceramic-mug-ding-03_nicholas-judy_tdc.wav"),
        ("Collect", "325805__wagna__collect.wav"),
        ("Cowbell", "809010__designerschoice__muscbell-blue-snowball-microphone-cu_cowbell-ding_nicholas-judy_tdc.wav"),
        ("Din Ding", "159158__daenn__din-ding.wav"),
        ("Ding", "434627__dr-macak__ding.wav"),
        ("Dolphin Robotic", "244455__milton__dolphin-robotic.wav"),
        ("Elevator Ding", "588718__collierhs_colinlib__elevator-ding.wav"),
        ("Gasp UI", "542013__rob_marion__gasp_ui_notification_2.wav"),
        ("High Bell", "625174__gabfitzgerald__ui-sound-approval-high-pitched-bell-synth.wav"),
        ("High Pitched", "624598__eqylizer__high-pitched-two-note-notification.wav"),
        ("Item 01", "523755__lilmati__item-01.wav"),
        ("Jeej", "319335__kurck__jeej.wav"),
        ("Message Alert", "740421__anthonyrox__message-notification-2.wav"),
        ("Microwave Ding", "264152__reitanna__microwave-ding.wav"),
        ("Modular Hit", "328603__modularsamples__modular-hits_11.wav"),
        ("Notification", "538149__fupicat__notification.wav"),
        ("Notification 3", "750609__deadrobotmusic__notification-sound-3.wav"),
        ("Notification Ding", "700332__notomorrow12__notification-ding.wav"),
        ("PD Kick", "494432__akustika__pd-kick-26.wav"),
        ("Powerup", "341227__jeremysykes__powerup.wav"),
        ("Powerup 2", "138486__justinvoke__powerup-2.wav"),
        ("Powerup Abbas", "411443__abbasgamez__powerup2.wav"),
        ("Powerup Sword", "397819__swordmaster767__powerup.wav"),
        ("Quiz Correct", "644945__craigscottuk__quiz-gameshow-correct-ding-01.wav"),
        ("Retro Bonus", "253172__suntemple__retro-bonus-pickup-sfx.wav"),
        ("Robot Ready", "187404__mazk1985__robot_ready.wav"),
        ("Single Ding", "759839__noisyredfox__singleding.wav"),
        ("System Sound", "789310__bnlc__system-sound-interval-p5.wav"),
        ("Yume Nikki Effect", "464902__plasterbrain__yume-nikki-effect-equip.wav")
    ]
    
    private init() {
        self.useTemplateIcon = UserDefaults.standard.bool(forKey: "useTemplateIcon")
        self.notificationSound = UserDefaults.standard.string(forKey: "notificationSound") ?? "None"
        self.launchAtLogin = UserDefaults.standard.bool(forKey: "launchAtLogin")
        
        // Default window height is 500, but read from UserDefaults if available
        let savedHeight = UserDefaults.standard.double(forKey: "windowHeight")
        self.windowHeight = savedHeight > 0 ? CGFloat(savedHeight) : 500.0
    }
    
    func playSound(_ soundName: String) {
        guard soundName != "None" else { return }
        
        // Try to find the sound file in the app bundle
        if let soundUrl = Bundle.main.url(forResource: soundName, withExtension: nil, subdirectory: "sounds") {
            let sound = NSSound(contentsOf: soundUrl, byReference: true)
            sound?.play()
        } else if let soundUrl = Bundle.main.url(forResource: soundName, withExtension: nil) {
            let sound = NSSound(contentsOf: soundUrl, byReference: true)
            sound?.play()
        } else {
            print("Could not find sound file: \(soundName)")
        }
    }
    
    func playCurrentSound() {
        playSound(notificationSound)
    }
    
    private func updateLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            if launchAtLogin {
                try? SMAppService.mainApp.register()
            } else {
                try? SMAppService.mainApp.unregister()
            }
        } else {
            // For older macOS versions, launch at login is not supported
            // The deprecated LSSharedFileList API is no longer available
        }
    }
}

extension Notification.Name {
    static let iconModeChanged = Notification.Name("iconModeChanged")
}