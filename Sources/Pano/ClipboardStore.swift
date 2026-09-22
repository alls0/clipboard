import AppKit
import Combine
import Foundation

struct Pinboard: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var colorHex: UInt32
}

struct ClipboardEntry: Identifiable, Codable, Equatable {
    var id: UUID
    var text: String
    var copiedAt: Date
    var sourceApp: String
    var sourceBundleIdentifier: String?
    var isPinned: Bool
    var pinboardIDs: Set<UUID>
    var label: String?
    var imageFilename: String?

    init(
        id: UUID,
        text: String,
        copiedAt: Date,
        sourceApp: String,
        sourceBundleIdentifier: String? = nil,
        isPinned: Bool,
        pinboardIDs: Set<UUID> = [],
        label: String? = nil,
        imageFilename: String? = nil
    ) {
        self.id = id
        self.text = text
        self.copiedAt = copiedAt
        self.sourceApp = sourceApp
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.isPinned = isPinned
        self.pinboardIDs = pinboardIDs
        self.label = label
        self.imageFilename = imageFilename
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, copiedAt, sourceApp, sourceBundleIdentifier, isPinned, pinboardIDs, label, imageFilename
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        text = try values.decode(String.self, forKey: .text)
        copiedAt = try values.decode(Date.self, forKey: .copiedAt)
        sourceApp = try values.decode(String.self, forKey: .sourceApp)
        sourceBundleIdentifier = try values.decodeIfPresent(String.self, forKey: .sourceBundleIdentifier)
        isPinned = try values.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        pinboardIDs = try values.decodeIfPresent(Set<UUID>.self, forKey: .pinboardIDs) ?? []
        label = try values.decodeIfPresent(String.self, forKey: .label)
        imageFilename = try values.decodeIfPresent(String.self, forKey: .imageFilename)
    }
}

@MainActor
final class ClipboardStore: ObservableObject {
    @Published private(set) var entries: [ClipboardEntry] = []
    @Published private(set) var pinboards: [Pinboard] = []
    @Published private(set) var storageError: String?
    @Published private(set) var clipboardAccessDenied = false
    @Published var isPaused: Bool {
        didSet {
            defaults.set(isPaused, forKey: Self.pausedDefaultsKey)
            // Changes made while paused must never be imported on resume.
            lastChangeCount = pasteboard.changeCount
        }
    }

    private static let pausedDefaultsKey = "Pano.isPaused"
    private static let maximumUnpinnedEntries = 200
    private static let maximumTextBytes = 256 * 1_024
    private static let maximumImageBytes = 10 * 1_024 * 1_024

    private let storageURL: URL
    private let pasteboard: NSPasteboard
    private let defaults: UserDefaults
    private var lastChangeCount: Int
    private var monitoringTimer: Timer?
    private var historyStorageError: String?
    private var pinboardStorageError: String?

    var imagesDirectory: URL {
        storageURL.deletingLastPathComponent().appendingPathComponent("images", isDirectory: true)
    }

    init(
        storageURL: URL? = nil,
        pasteboard: NSPasteboard = .general,
        defaults: UserDefaults = .standard,
        startMonitoring: Bool = true
    ) {
        self.storageURL = storageURL ?? Self.defaultStorageURL
        self.pasteboard = pasteboard
        self.defaults = defaults
        self.lastChangeCount = pasteboard.changeCount
        self.isPaused = defaults.bool(forKey: Self.pausedDefaultsKey)
        loadPinboards()
        loadHistory()
        updateClipboardAccessState()
        if startMonitoring {
            self.startMonitoring()
        }
    }

    isolated deinit {
        monitoringTimer?.invalidate()
    }

    func startMonitoring() {
        guard monitoringTimer == nil else { return }
        // A newly launched app starts with future copies, not the existing clipboard.
        lastChangeCount = pasteboard.changeCount
        let timer = Timer(timeInterval: 0.65, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkForChanges()
            }
        }
        monitoringTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopMonitoring() {
        monitoringTimer?.invalidate()
        monitoringTimer = nil
    }

    func checkForChanges() {
        updateClipboardAccessState()
        let currentChangeCount = pasteboard.changeCount
        guard currentChangeCount != lastChangeCount else { return }
        lastChangeCount = currentChangeCount
        guard !isPaused, !clipboardAccessDenied, !containsPrivatePasteboardType() else { return }

        let source = NSWorkspace.shared.frontmostApplication
        let sourceApp = source?.localizedName ?? "Bilinmeyen uygulama"
        let sourceBundleID = source?.bundleIdentifier

        // Check for image content first
        if let imageData = imageDataFromPasteboard() {
            guard pasteboard.changeCount == currentChangeCount else { return }
            addImage(
                imageData: imageData,
                sourceApp: sourceApp,
                sourceBundleIdentifier: sourceBundleID
            )
            return
        }

        // Then check for text
        guard let text = pasteboard.string(forType: .string) else { return }
        // Do not combine the privacy markers from one copy with a later copy's text.
        guard pasteboard.changeCount == currentChangeCount else { return }
        add(
            text: text,
            sourceApp: sourceApp,
            sourceBundleIdentifier: sourceBundleID
        )
    }

    @discardableResult
    func copy(_ entry: ClipboardEntry) -> Bool {
        pasteboard.clearContents()
        var succeeded = false
        if let imageFilename = entry.imageFilename {
            let imageURL = imagesDirectory.appendingPathComponent(imageFilename)
            if let imageData = try? Data(contentsOf: imageURL) {
                succeeded = pasteboard.setData(imageData, forType: .png)
            }
        } else {
            succeeded = pasteboard.setString(entry.text, forType: .string)
        }
        lastChangeCount = pasteboard.changeCount
        guard succeeded else { return false }
        // Re-add to move to front
        if entry.imageFilename != nil {
            // For images, just move to front without re-saving the image
            moveToFront(entry)
        } else {
            add(
                text: entry.text,
                sourceApp: entry.sourceApp,
                sourceBundleIdentifier: entry.sourceBundleIdentifier
            )
        }
        return true
    }

    func togglePin(_ entry: ClipboardEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].isPinned.toggle()
        trimHistory()
        saveHistory()
    }

    func delete(_ entry: ClipboardEntry) {
        guard entries.contains(where: { $0.id == entry.id }) else { return }
        // Clean up image file if present
        if let imageFilename = entry.imageFilename {
            let imageURL = imagesDirectory.appendingPathComponent(imageFilename)
            try? FileManager.default.removeItem(at: imageURL)
        }
        entries.removeAll { $0.id == entry.id }
        saveHistory()
    }

    func clearHistory() {
        let removedEntries = entries.filter { !$0.isPinned && $0.pinboardIDs.isEmpty }
        for entry in removedEntries {
            if let imageFilename = entry.imageFilename {
                let imageURL = imagesDirectory.appendingPathComponent(imageFilename)
                try? FileManager.default.removeItem(at: imageURL)
            }
        }
        entries.removeAll { !$0.isPinned && $0.pinboardIDs.isEmpty }
        saveHistory()
    }

    func clearAll() {
        for entry in entries {
            if let imageFilename = entry.imageFilename {
                let imageURL = imagesDirectory.appendingPathComponent(imageFilename)
                try? FileManager.default.removeItem(at: imageURL)
            }
        }
        entries.removeAll()
        saveHistory()
    }

    @discardableResult
    func createPinboard(name: String, colorHex: UInt32 = 0xED6A5E) -> Pinboard? {
        guard let name = validPinboardName(name) else { return nil }
        let board = Pinboard(id: UUID(), name: name, colorHex: colorHex)
        pinboards.append(board)
        savePinboards()
        return board
    }

    @discardableResult
    func renamePinboard(_ board: Pinboard, name: String) -> Bool {
        guard let index = pinboards.firstIndex(where: { $0.id == board.id }),
              let name = validPinboardName(name, excluding: board.id) else { return false }
        pinboards[index].name = name
        savePinboards()
        return true
    }

    func setPinboardColor(_ board: Pinboard, colorHex: UInt32) {
        guard let index = pinboards.firstIndex(where: { $0.id == board.id }) else { return }
        pinboards[index].colorHex = colorHex
        savePinboards()
    }

    func deletePinboard(_ board: Pinboard) {
        guard pinboards.contains(where: { $0.id == board.id }) else { return }
        pinboards.removeAll { $0.id == board.id }
        for index in entries.indices {
            entries[index].pinboardIDs.remove(board.id)
        }
        // Removing a collection must not remove the clipboard items it contained.
        savePinboards()
        saveHistory()
    }

    func toggleMembership(_ entry: ClipboardEntry, in board: Pinboard) {
        guard pinboards.contains(where: { $0.id == board.id }),
              let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        if entries[index].pinboardIDs.contains(board.id) {
            entries[index].pinboardIDs.remove(board.id)
        } else {
            entries[index].pinboardIDs.insert(board.id)
        }
        saveHistory()
    }

    func setLabel(_ entry: ClipboardEntry, label: String?) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        entries[index].label = trimmed.flatMap { $0.isEmpty ? nil : $0 }
        saveHistory()
    }

    func add(
        text: String,
        sourceApp: String,
        sourceBundleIdentifier: String? = nil,
        at date: Date = Date()
    ) {
        guard Self.isValidText(text) else { return }
        let previous = entries.first { $0.text == text && $0.imageFilename == nil }
        entries.removeAll { $0.text == text && $0.imageFilename == nil }
        entries.insert(
            ClipboardEntry(
                id: previous?.id ?? UUID(),
                text: text,
                copiedAt: date,
                sourceApp: sourceApp,
                sourceBundleIdentifier: sourceBundleIdentifier,
                isPinned: previous?.isPinned ?? false,
                pinboardIDs: previous?.pinboardIDs ?? [],
                label: previous?.label
            ),
            at: 0
        )
        trimHistory()
        saveHistory()
    }

    func addImage(
        imageData: Data,
        sourceApp: String,
        sourceBundleIdentifier: String? = nil,
        at date: Date = Date()
    ) {
        guard imageData.count <= Self.maximumImageBytes, !imageData.isEmpty else { return }

        let filename = UUID().uuidString + ".png"
        do {
            try FileManager.default.createDirectory(
                at: imagesDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let fileURL = imagesDirectory.appendingPathComponent(filename)
            try imageData.write(to: fileURL, options: .atomic)
        } catch {
            return
        }

        let description = "Resim (\(imageData.count.formattedByteCount))"
        entries.insert(
            ClipboardEntry(
                id: UUID(),
                text: description,
                copiedAt: date,
                sourceApp: sourceApp,
                sourceBundleIdentifier: sourceBundleIdentifier,
                isPinned: false,
                imageFilename: filename
            ),
            at: 0
        )
        trimHistory()
        saveHistory()
    }

    func loadImage(for entry: ClipboardEntry) -> NSImage? {
        guard let filename = entry.imageFilename else { return nil }
        let url = imagesDirectory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return NSImage(data: data)
    }

    // MARK: - Private

    private func moveToFront(_ entry: ClipboardEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        var moved = entries.remove(at: index)
        moved.copiedAt = Date()
        entries.insert(moved, at: 0)
        saveHistory()
    }

    private func imageDataFromPasteboard() -> Data? {
        // Try PNG first, then TIFF, then check for file URLs pointing to images
        if let data = pasteboard.data(forType: .png), data.count <= Self.maximumImageBytes {
            return data
        }
        if let data = pasteboard.data(forType: .tiff), data.count <= Self.maximumImageBytes {
            // Convert TIFF to PNG for consistent storage
            if let image = NSImage(data: data),
               let tiffRep = image.tiffRepresentation,
               let bitmapRep = NSBitmapImageRep(data: tiffRep),
               let pngData = bitmapRep.representation(using: .png, properties: [:]) {
                return pngData.count <= Self.maximumImageBytes ? pngData : nil
            }
        }
        return nil
    }

    private static var defaultStorageURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("Pano", isDirectory: true)
            .appendingPathComponent("history.json")
    }

    private static func isValidText(_ text: String) -> Bool {
        text.utf8.count <= maximumTextBytes
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var pinboardsURL: URL {
        storageURL.deletingLastPathComponent().appendingPathComponent("pinboards.json")
    }

    private func validPinboardName(_ proposedName: String, excluding id: UUID? = nil) -> String? {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40,
              !pinboards.contains(where: {
                  $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame
              }) else { return nil }
        return name
    }

    private func updateClipboardAccessState() {
        if #available(macOS 15.4, *) {
            let denied = pasteboard.accessBehavior == .alwaysDeny
            if clipboardAccessDenied != denied {
                clipboardAccessDenied = denied
            }
        }
    }

    private func containsPrivatePasteboardType() -> Bool {
        let types = (pasteboard.types ?? [])
            + (pasteboard.pasteboardItems ?? []).flatMap(\.types)
        return types.contains { type in
            let name = type.rawValue.lowercased()
            return name == "org.nspasteboard.transienttype"
                || name == "org.nspasteboard.concealedtype"
                || name == "org.nspasteboard.autogeneratedtype"
                || name.hasPrefix("com.agilebits.onepassword")
                || name.hasPrefix("com.1password.")
                || name.hasPrefix("org.keepassxc.")
                || name.hasPrefix("com.lastpass.")
                || name.hasPrefix("com.bitwarden.")
        }
    }

    private func trimHistory() {
        var unpinnedCount = 0
        var removedEntries: [ClipboardEntry] = []
        entries = entries.filter { entry in
            guard !entry.isPinned && entry.pinboardIDs.isEmpty else { return true }
            unpinnedCount += 1
            if unpinnedCount > Self.maximumUnpinnedEntries {
                removedEntries.append(entry)
                return false
            }
            return true
        }
        // Clean up image files for trimmed entries
        for entry in removedEntries {
            if let imageFilename = entry.imageFilename {
                let imageURL = imagesDirectory.appendingPathComponent(imageFilename)
                try? FileManager.default.removeItem(at: imageURL)
            }
        }
    }

    private func loadHistory() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            let decoded = try JSONDecoder().decode([ClipboardEntry].self, from: data)
            var seenTexts = Set<String>()
            var seenIDs = Set<UUID>()
            entries = decoded.filter { entry in
                // Image entries use imageFilename as uniqueness key
                let uniqueKey = entry.imageFilename ?? entry.text
                return (entry.imageFilename != nil || Self.isValidText(entry.text))
                    && seenTexts.insert(uniqueKey).inserted
                    && seenIDs.insert(entry.id).inserted
            }
            trimHistory()
            historyStorageError = nil
        } catch {
            historyStorageError = "Pano geçmişi okunamadı. Yeni kopyalar bu oturumda gösterilecek."
        }
        refreshStorageError()
    }

    private func saveHistory() {
        do {
            try saveJSON(entries, to: storageURL)
            historyStorageError = nil
        } catch {
            historyStorageError = "Pano geçmişi kaydedilemedi. Yeni kopyalar bu oturumda gösterilecek."
        }
        refreshStorageError()
    }

    private func loadPinboards() {
        guard FileManager.default.fileExists(atPath: pinboardsURL.path) else { return }
        do {
            let data = try Data(contentsOf: pinboardsURL)
            let decoded = try JSONDecoder().decode([Pinboard].self, from: data)
            for board in decoded {
                guard !pinboards.contains(where: { $0.id == board.id }),
                      let name = validPinboardName(board.name) else { continue }
                pinboards.append(Pinboard(id: board.id, name: name, colorHex: board.colorHex))
            }
            pinboardStorageError = nil
        } catch {
            pinboardStorageError = "Koleksiyonlar okunamadı. Kaydedilmiş metinlerin geçmişte korunur."
        }
        refreshStorageError()
    }

    private func savePinboards() {
        do {
            try saveJSON(pinboards, to: pinboardsURL)
            pinboardStorageError = nil
        } catch {
            pinboardStorageError = "Koleksiyonlar kaydedilemedi. Değişikliklerin bu oturumda gösterilecek."
        }
        refreshStorageError()
    }

    private func refreshStorageError() {
        storageError = historyStorageError ?? pinboardStorageError
    }

    private func saveJSON<Value: Encodable>(_ value: Value, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}

extension Int {
    var formattedByteCount: String {
        if self < 1_024 { return "\(self) B" }
        if self < 1_024 * 1_024 { return "\(self / 1_024) KB" }
        return String(format: "%.1f MB", Double(self) / (1_024.0 * 1_024.0))
    }
}
