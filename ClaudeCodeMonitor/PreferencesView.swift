import SwiftUI

struct PreferencesView: View {
    @ObservedObject var preferencesManager = PreferencesManager.shared
    @State private var selectedSoundIndex = 0
    var onDismiss: (() -> Void)?
    
    init(onDismiss: (() -> Void)? = nil) {
        self.onDismiss = onDismiss
        // Find the index of the currently selected sound
        if let index = PreferencesManager.shared.availableSounds.firstIndex(where: { $0.1 == PreferencesManager.shared.notificationSound }) {
            _selectedSoundIndex = State(initialValue: index)
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Preferences")
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.bottom, 10)
            
            GroupBox("General") {
                Toggle("Launch at login", isOn: $preferencesManager.launchAtLogin)
                    .padding(.vertical, 5)
            }
            
            GroupBox("Appearance") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Use dark/light mode for icon", isOn: $preferencesManager.useTemplateIcon)
                    
                    HStack {
                        Text("Window height:")
                        Slider(value: $preferencesManager.windowHeight, in: 300...800, step: 50)
                        Text("\(Int(preferencesManager.windowHeight))px")
                            .frame(width: 50, alignment: .trailing)
                    }
                }
                .padding(.vertical, 5)
            }
            
            GroupBox("Notifications") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Sound when Claude finishes working:")
                        .font(.subheadline)
                    
                    HStack {
                        Picker("", selection: $selectedSoundIndex) {
                            ForEach(0..<preferencesManager.availableSounds.count, id: \.self) { index in
                                Text(preferencesManager.availableSounds[index].0)
                                    .tag(index)
                            }
                        }
                        .pickerStyle(PopUpButtonPickerStyle())
                        .frame(width: 200)
                        .onChange(of: selectedSoundIndex) { newValue in
                            preferencesManager.notificationSound = preferencesManager.availableSounds[newValue].1
                            preferencesManager.playCurrentSound()
                        }
                        
                        Button("Test") {
                            preferencesManager.playCurrentSound()
                        }
                        .disabled(preferencesManager.notificationSound == "None")
                    }
                }
            }
                        
            HStack {
                Button("Done") {
                    onDismiss?()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 450, height: 420)
    }
}

struct PreferencesView_Previews: PreviewProvider {
    static var previews: some View {
        PreferencesView()
    }
}