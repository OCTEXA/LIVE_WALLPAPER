//
//  LiveWallpaperApp.swift
//
//  Created on 13/01/25 By Octexa
//

import SwiftUI
import AppKit
import AVKit
import SwiftData
import AppKit
import AVFoundation
import CoreAudio
import CoreImage
import ScreenCaptureKit
import IOKit.ps

// MARK: - Data Model
@Model
class WallpaperSettings {
    var lastUsedPath: String?
    var autoStart: Bool
    var playbackMode: PlaybackMode
    var adaptiveMenuBar: Bool
    var thumbnailData: Data?
    var batteryLimitEnabled: Bool
    var batteryLimitPercentage: Double
    
    init(lastUsedPath: String? = nil, autoStart: Bool = false, playbackMode: PlaybackMode = .loop, adaptiveMenuBar: Bool = true, thumbnailData: Data? = nil, batteryLimitEnabled: Bool = false, batteryLimitPercentage: Double = 20) {
        self.lastUsedPath = lastUsedPath
        self.autoStart = autoStart
        self.playbackMode = playbackMode
        self.adaptiveMenuBar = adaptiveMenuBar
        self.thumbnailData = thumbnailData
        self.batteryLimitEnabled = batteryLimitEnabled
        self.batteryLimitPercentage = batteryLimitPercentage
    }
    
    enum PlaybackMode: String, Codable {
        case loop, shuffle, once
    }
}

// MARK: - Battery Monitor
class BatteryMonitor {
    static let shared = BatteryMonitor()
    private var timer: Timer?
    var onBatteryLevelChanged: ((Double, Bool) -> Void)?
    
    private init() {
        startMonitoring()
    }
    
    private func startMonitoring() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkBatteryStatus()
        }
        timer?.fire() // Initial check
    }
    
    private func checkBatteryStatus() {
        if let powerSource = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(powerSource)?.takeRetainedValue() as? [CFTypeRef] {
            
            for source in sources {
                if let description = IOPSGetPowerSourceDescription(powerSource, source)?.takeUnretainedValue() as? [String: Any] {
                    let isCharging = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
                    let batteryLevel = Double(description[kIOPSCurrentCapacityKey] as? Int ?? 100)
                    let percentage = batteryLevel
                    
                    DispatchQueue.main.async {
                        self.onBatteryLevelChanged?(percentage, isCharging)
                    }
                }
            }
        }
    }
    
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }
}



// MARK: - Persistence Manager
class PersistenceManager {
    static let shared = PersistenceManager()
    
    private init() {}
    
    func createContainer() -> ModelContainer {
        let schema = Schema([WallpaperSettings.self])
        
        let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolderURL = appSupportURL.appendingPathComponent("LiveWallpaper", isDirectory: true)
        
        try? FileManager.default.createDirectory(at: appFolderURL, withIntermediateDirectories: true)
        
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            url: appFolderURL.appendingPathComponent("WallpaperSettings.store"),
            allowsSave: true
        )
        
        do {
            let container = try ModelContainer(
                for: schema,
                configurations: [modelConfiguration]
            )
            
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<WallpaperSettings>()
            
            if let existingSettings = try? context.fetch(descriptor),
               existingSettings.isEmpty {
                let defaultSettings = WallpaperSettings()
                context.insert(defaultSettings)
                try? context.save()
            }
            
            return container
        } catch {
            print("Error creating persistent container: \(error.localizedDescription)")
            return try! ModelContainer(
                for: schema,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        }
    }
}

// MARK: - Color Sampling Manager
class ColorSamplingManager {
    static let shared = ColorSamplingManager()
    
    private init() {}
    
    func getDominantColor(from image: NSImage) -> NSColor {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return .systemBlue
        }
        
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let bitsPerComponent = 8
        
        var rawData = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        
        guard let context = CGContext(
            data: &rawData,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            return .systemBlue
        }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        var totalRed = 0
        var totalGreen = 0
        var totalBlue = 0
        var totalPixels = 0
        
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * bytesPerRow) + (x * bytesPerPixel)
                let alpha = CGFloat(rawData[offset + 3]) / 255.0
                
                if alpha > 0.1 {
                    totalRed += Int(rawData[offset])
                    totalGreen += Int(rawData[offset + 1])
                    totalBlue += Int(rawData[offset + 2])
                    totalPixels += 1
                }
            }
        }
        
        guard totalPixels > 0 else {
            return .systemBlue
        }
        
        let averageRed = CGFloat(totalRed) / CGFloat(totalPixels) / 255.0
        let averageGreen = CGFloat(totalGreen) / CGFloat(totalPixels) / 255.0
        let averageBlue = CGFloat(totalBlue) / CGFloat(totalPixels) / 255.0
        
        return NSColor(red: averageRed, green: averageGreen, blue: averageBlue, alpha: 1.0)
    }
}

// MARK: - Model Manager
class ModelManager: ObservableObject {
    static let shared = ModelManager()
    @Published var settings: WallpaperSettings?
    private var modelContext: ModelContext?
    
    private init() {}
    
    func initialize(with context: ModelContext) {
        self.modelContext = context
        loadSettings()
    }
    
    func loadSettings() {
        let descriptor = FetchDescriptor<WallpaperSettings>()
        
        do {
            let results = try modelContext?.fetch(descriptor)
            settings = results?.first ?? createDefaultSettings()
        } catch {
            print("Error loading settings: \(error.localizedDescription)")
            settings = createDefaultSettings()
        }
    }
    
    private func createDefaultSettings() -> WallpaperSettings {
        let newSettings = WallpaperSettings()
        modelContext?.insert(newSettings)
        try? modelContext?.save()
        return newSettings
    }
    
    func updateSettings() {
        try? modelContext?.save()
    }
}

// MARK: - Menu Bar Controller
class MenuBarController: ObservableObject {
    private var statusItem: NSStatusItem?
    @Published var isVisible = true
    
    init() {
        setupStatusItem()
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon(isActive: false)
    }
    
    func updateIcon(isActive: Bool, color: NSColor? = nil) {
        let imageName = isActive ? "play.circle.fill" : "play.circle"
        guard let image = NSImage(systemSymbolName: imageName, accessibilityDescription: isActive ? "Active" : "Inactive") else { return }
        
        if let color = color {
            statusItem?.button?.contentTintColor = color
        }
        
        statusItem?.button?.image = image
        statusItem?.button?.image?.isTemplate = color == nil
    }
    
    func setMenu(_ menu: NSMenu) {
        statusItem?.menu = menu
    }
}

// MARK: - Window Manager
class WallpaperWindowManager: ObservableObject {
    private var window: NSWindow?
    private var playerView: AVPlayerView?
    private var player: AVPlayer?
    private var menuBarController: MenuBarController
    private let colorSamplingManager = ColorSamplingManager.shared
    private let batteryMonitor = BatteryMonitor.shared
    private var wasPlayingBeforeLostFocus = false
    
    @Published var isPlaying: Bool = false {
        didSet {
            if isPlaying {
                startColorSampling()
            } else {
                stopColorSampling()
                menuBarController.updateIcon(isActive: false)
            }
        }
    }
    
    init(menuBarController: MenuBarController) {
        self.menuBarController = menuBarController
        setupWindow()
        setupWorkspaceNotifications()
        setupBatteryMonitoring()
    }
    
    private func setupBatteryMonitoring() {
        batteryMonitor.onBatteryLevelChanged = { [weak self] batteryLevel, isCharging in
            guard let self = self,
                  let settings = ModelManager.shared.settings,
                  settings.batteryLimitEnabled else { return }
            
            if !isCharging && batteryLevel <= settings.batteryLimitPercentage && self.isPlaying {
                DispatchQueue.main.async {
                    self.stop()
                }
            }
        }
    }
    
    private func setupWindow() {
        guard let screen = NSScreen.main else { return }
        
        class BackgroundWindow: NSWindow {
            override var canBecomeKey: Bool { return false }
            override var canBecomeMain: Bool { return false }
        }
        
        window = BackgroundWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        configureWindow()
        setupPlayerView()
    }
    
    private func configureWindow() {
        window?.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window?.backgroundColor = .clear
        window?.isOpaque = false
        window?.hasShadow = false
        window?.ignoresMouseEvents = true
        window?.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window?.isExcludedFromWindowsMenu = true
        window?.tabbingMode = .disallowed
    }
    
    private func setupPlayerView() {
        playerView = AVPlayerView()
        playerView?.controlsStyle = .none
        playerView?.videoGravity = .resizeAspectFill
        playerView?.allowsPictureInPicturePlayback = false
        window?.contentView = playerView
    }
    
    private func setupWorkspaceNotifications() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleActiveAppChanged),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }
    
    @objc private func handleActiveAppChanged(_ notification: Notification) {
        guard let activeApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        
        if activeApp.bundleIdentifier == "com.apple.finder" {
            if wasPlayingBeforeLostFocus {
                resumePlayback()
            }
        } else {
            if isPlaying {
                wasPlayingBeforeLostFocus = true
                pausePlayback()
            }
        }
    }
    
    private func startColorSampling() {
        guard let playerView = playerView,
              ModelManager.shared.settings?.adaptiveMenuBar == true else {
            menuBarController.updateIcon(isActive: true)
            return
        }
        
        if let currentItem = player?.currentItem {
            let imageGenerator = AVAssetImageGenerator(asset: currentItem.asset)
            imageGenerator.appliesPreferredTrackTransform = true
            
            Task {
                do {
                    let time = CMTime(seconds: 0, preferredTimescale: 600)
                    let cgImage = try await imageGenerator.image(at: time).image
                    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: 100, height: 100))
                    
                    let dominantColor = ColorSamplingManager.shared.getDominantColor(from: nsImage)
                    await MainActor.run {
                        self.menuBarController.updateIcon(isActive: true, color: dominantColor)
                    }
                } catch {
                    print("Error generating thumbnail for color sampling: \(error)")
                    await MainActor.run {
                        self.menuBarController.updateIcon(isActive: true)
                    }
                }
            }
        }
    }
    
    private func stopColorSampling() {
        menuBarController.updateIcon(isActive: false)
    }
    
    func setVideo(url: URL) {
        let asset = AVAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)
        configureAudioSettings(for: playerItem, with: asset)
        setupPlayer(with: playerItem)
    }
    
    private func configureAudioSettings(for playerItem: AVPlayerItem, with asset: AVAsset) {
        Task {
            do {
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                
                if let audioTrack = audioTracks.first {
                    await MainActor.run {
                        let audioMix = AVMutableAudioMix()
                        let audioInputParameters = AVMutableAudioMixInputParameters(track: audioTrack)
                        audioInputParameters.setVolume(0, at: .zero)
                        audioMix.inputParameters = [audioInputParameters]
                        playerItem.audioMix = audioMix
                    }
                }
            } catch {
                print("Error loading audio tracks: \(error.localizedDescription)")
            }
        }
    }
    
    private func setupPlayer(with playerItem: AVPlayerItem) {
        if player == nil {
            player = AVPlayer(playerItem: playerItem)
            player?.isMuted = true
            playerView?.player = player
        } else {
            player?.replaceCurrentItem(with: playerItem)
        }
        
        player?.allowsExternalPlayback = false
                setupLooping(for: playerItem)
            }
            
            private func setupLooping(for playerItem: AVPlayerItem) {
                NotificationCenter.default.removeObserver(self)
                NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime,
                    object: playerItem,
                    queue: .main
                ) { [weak self] _ in
                    self?.player?.seek(to: .zero)
                    self?.player?.play()
                }
            }
            
            private func pausePlayback() {
                player?.pause()
            }
            
            private func resumePlayback() {
                player?.play()
                wasPlayingBeforeLostFocus = false
            }
            
            func start() {
                window?.orderFront(nil)
                player?.play()
                isPlaying = true
            }
            
            func stop() {
                wasPlayingBeforeLostFocus = false
                player?.pause()
                window?.orderOut(nil)
                isPlaying = false
            }
            
            func cleanup() {
                stopColorSampling()
                player?.pause()
                player = nil
                window?.close()
                window = nil
            }
        }

        // MARK: - Preview Player Manager
        class PreviewPlayerManager: ObservableObject {
            @MainActor @Published private(set) var previewImage: NSImage?
            private var player: AVPlayer?
            private var playerLayer: AVPlayerLayer?
            private var videoOutput: AVPlayerItemVideoOutput?
            
            @MainActor
            func setupPreview(url: URL, completion: ((Data?) -> Void)? = nil) {
                let asset = AVAsset(url: url)
                let imageGenerator = AVAssetImageGenerator(asset: asset)
                imageGenerator.appliesPreferredTrackTransform = true
                
                Task {
                    do {
                        let time = CMTime(seconds: 0, preferredTimescale: 600)
                        let cgImage = try await imageGenerator.image(at: time).image
                        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: 280, height: 158))
                        
                        await MainActor.run {
                            self.previewImage = nsImage
                            
                            if let tiffData = nsImage.tiffRepresentation,
                               let bitmap = NSBitmapImageRep(data: tiffData),
                               let thumbnailData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) {
                                completion?(thumbnailData)
                            } else {
                                completion?(nil)
                            }
                        }
                    } catch {
                        print("Could not generate thumbnail: \(error)")
                        await MainActor.run {
                            self.previewImage = nil
                            completion?(nil)
                        }
                    }
                }
                
                cleanup()
            }
            
            @MainActor
            func setPreviewFromData(_ data: Data?) {
                guard let data = data else {
                    previewImage = nil
                    return
                }
                
                if let nsImage = NSImage(data: data) {
                    previewImage = nsImage
                }
            }
            
            func cleanup() {
                Task { @MainActor in
                    player?.pause()
                    player = nil
                    playerLayer = nil
                    videoOutput = nil
                }
            }
        }




        // MARK: - Custom Button Styles
        struct AccentButtonStyle: ButtonStyle {
            @Environment(\.controlActiveState) private var controlActiveState
            
            func makeBody(configuration: Configuration) -> some View {
                configuration.label
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    .background(Color.accentColor.opacity(configuration.isPressed ? 0.8 : 1))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    .opacity(controlActiveState == .inactive ? 0.5 : 1)
            }
        }

        struct SecondaryButtonStyle: ButtonStyle {
            func makeBody(configuration: Configuration) -> some View {
                configuration.label
                    .foregroundColor(.primary)
                    .opacity(configuration.isPressed ? 0.7 : 1)
            }
        }

        // MARK: - Content View
        struct ContentView: View {
            @Environment(\.modelContext) private var modelContext
            @StateObject private var windowManager: WallpaperWindowManager
            @ObservedObject private var modelManager = ModelManager.shared
            @StateObject private var previewManager = PreviewPlayerManager()
            @Environment(\.colorScheme) private var colorScheme
            
            init(menuBarController: MenuBarController) {
                _windowManager = StateObject(wrappedValue: WallpaperWindowManager(menuBarController: menuBarController))
            }
            
            var body: some View {
                VStack(spacing: 16) {
                    Text("Live Wallpaper 👀")
                        .font(.system(size: 24, weight: .bold))
                        .padding(.top, 8)
                    
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(nsColor: .windowBackgroundColor))
                            .frame(height: 158)
                        
                        Group {
                            if let previewImage = previewManager.previewImage {
                                Image(nsImage: previewImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxWidth: 280, maxHeight: 158)
                                    .cornerRadius(8)
                            } else {
                                VStack {
                                    Image(systemName: "photo.fill")
                                        .font(.system(size: 30))
                                        .foregroundColor(.gray)
                                    Text("No wallpaper selected")
                                        .foregroundColor(.gray)
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                    
                    HStack(spacing: 12) {
                        Button(action: chooseVideo) {
                            Label("Choose", systemImage: "plus.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(AccentButtonStyle())
                        
                        Button(action: togglePlayback) {
                            Label(
                                windowManager.isPlaying ? "Stop" : "Start",
                                systemImage: windowManager.isPlaying ? "stop.fill" : "play.fill"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(AccentButtonStyle())
                    }
                    .padding(.horizontal)
                    
                    VStack(spacing: 8) {
                        Toggle("Auto-start on launch", isOn: Binding(
                            get: { modelManager.settings?.autoStart ?? false },
                            set: { updateAutoStart($0) }
                        ))
                        
                        Toggle("Adaptive menu bar color", isOn: Binding(
                            get: { modelManager.settings?.adaptiveMenuBar ?? true },
                            set: { updateAdaptiveMenuBar($0) }
                        ))
                        
                        Toggle("Stop when battery is low", isOn: Binding(
                            get: { modelManager.settings?.batteryLimitEnabled ?? false },
                            set: { updateBatteryLimit($0) }
                        ))
                        
                        if modelManager.settings?.batteryLimitEnabled == true {
                            HStack {
                                Slider(value: Binding(
                                    get: { modelManager.settings?.batteryLimitPercentage ?? 20 },
                                    set: { updateBatteryLimitPercentage($0) }
                                ), in: 10...80, step: 5)
                                .accentColor(.accentColor)
                                
                                Text("\(Int(modelManager.settings?.batteryLimitPercentage ?? 20))%")
                                    .foregroundColor(.secondary)
                                    .frame(width: 45, alignment: .trailing)
                            }
                            .padding(.horizontal, 4)
                        }
                    }
                    .padding(.horizontal)
                    
                    Divider()
                        .padding(.vertical, 8)
                    
                    Button("Quit Application") {
                        NSApplication.shared.terminate(nil)
                    }
                    .buttonStyle(BorderedButtonStyle())
                    
                    Text("Made with ❤️ by octexa")
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .fontWeight(.bold)
                    
                    Text("Version 1.0.0")
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .padding(.bottom, 2)
                        .fontWeight(.bold)
                    
                    Text("Under Development Bugs may Occur")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.accentColor)
                        .padding(.bottom, 8)
                }
                .frame(width: 320)
                .onAppear {
                    modelManager.initialize(with: modelContext)
                    handleOnAppear()
                }
            }
            
            private func chooseVideo() {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.movie]
                panel.allowsMultipleSelection = false
                
                panel.begin { response in
                    if response == .OK, let url = panel.url {
                        modelManager.settings?.lastUsedPath = url.absoluteString
                        previewManager.setupPreview(url: url) { thumbnailData in
                            modelManager.settings?.thumbnailData = thumbnailData
                            modelManager.updateSettings()
                        }
                        windowManager.setVideo(url: url)
                        windowManager.start()
                    }
                }
            }
            
            private func handleOnAppear() {
                previewManager.setPreviewFromData(modelManager.settings?.thumbnailData)
                
                if let path = modelManager.settings?.lastUsedPath,
                   let url = URL(string: path),
                   modelManager.settings?.autoStart == true {
                    windowManager.setVideo(url: url)
                    windowManager.start()
                }
            }
            
            private func togglePlayback() {
                if windowManager.isPlaying {
                    windowManager.stop()
                } else if let path = modelManager.settings?.lastUsedPath,
                          let url = URL(string: path) {
                    windowManager.setVideo(url: url)
                    windowManager.start()
                }
            }
            
            private func updateAutoStart(_ value: Bool) {
                modelManager.settings?.autoStart = value
                modelManager.updateSettings()
            }
            
            private func updateAdaptiveMenuBar(_ value: Bool) {
                modelManager.settings?.adaptiveMenuBar = value
                modelManager.updateSettings()
            }
            
            private func updateBatteryLimit(_ value: Bool) {
                modelManager.settings?.batteryLimitEnabled = value
                modelManager.updateSettings()
            }
            
            private func updateBatteryLimitPercentage(_ value: Double) {
                modelManager.settings?.batteryLimitPercentage = value
                modelManager.updateSettings()
            }
        }

        // MARK: - Main Scene
        struct MainScene: Scene {
            @StateObject private var menuBarController = MenuBarController()
            let modelContainer: ModelContainer
            
            var body: some Scene {
                MenuBarExtra {
                    ContentView(menuBarController: menuBarController)
                        .modelContainer(modelContainer)
                } label: {
                    Text("👀")
                }
                .menuBarExtraStyle(.window)
            }
        }

        // MARK: - App Entry Point
        @main
        struct LiveWallpaperApp: App {
            let modelContainer: ModelContainer
            
            init() {
                self.modelContainer = PersistenceManager.shared.createContainer()
            }
            
            var body: some Scene {
                MainScene(modelContainer: modelContainer)
            }
        }
