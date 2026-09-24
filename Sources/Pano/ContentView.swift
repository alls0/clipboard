import AppKit
import SwiftUI

// MARK: - Adaptive Theme (Light + Dark)

private struct PasteTheme {
    let isDark: Bool

    init(_ colorScheme: ColorScheme) {
        self.isDark = colorScheme == .dark
    }

    // Panel
    var panelBG: Color { isDark ? Color(red: 0.11, green: 0.11, blue: 0.12) : Color(red: 0.97, green: 0.97, blue: 0.98) }
    var panelStroke: Color { isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.08) }
    var handleColor: Color { isDark ? Color.white.opacity(0.15) : Color.black.opacity(0.12) }

    // Accent
    let accent = Color(hex: 0xF5A623)

    // Text
    var textPrimary: Color { isDark ? .white : Color(red: 0.13, green: 0.13, blue: 0.15) }
    var textSecondary: Color { isDark ? Color(red: 0.56, green: 0.56, blue: 0.58) : Color(red: 0.44, green: 0.44, blue: 0.47) }
    var textTertiary: Color { isDark ? Color(red: 0.38, green: 0.38, blue: 0.40) : Color(red: 0.62, green: 0.62, blue: 0.65) }

    // Cards
    var cardBG: Color { isDark ? Color(red: 0.16, green: 0.16, blue: 0.18) : .white }
    var cardBorder: Color { isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.08) }
    var cardHoverBorder: Color { isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.14) }
    var cardShadow: Color { isDark ? .black.opacity(0.2) : .black.opacity(0.06) }

    // UI
    var searchBG: Color { isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.04) }
    var searchBorder: Color { isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.08) }
    var pillBG: Color { isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.05) }
    var pillActiveBG: Color { isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.10) }
    var ctaFG: Color { isDark ? .black : .white }
    var codeColor: Color { isDark ? Color(hex: 0xA8C7FA) : Color(hex: 0x48556C) }
    var colorLabel: Color { isDark ? .white : Color(red: 0.2, green: 0.2, blue: 0.22) }
    var previewBG: Color { isDark ? Color.black.opacity(0.15) : Color.black.opacity(0.04) }
    var frostedMaterial: NSVisualEffectView.Material { isDark ? .hudWindow : .popover }

    static let boardColors: [UInt32] = [0xF0646B, 0xF4AB43, 0x56B88A, 0x4992EF, 0xA77AE0, 0xD87CA5]
}

private enum Shelf: Hashable {
    case history, favorites, board(UUID)
}

struct ContentView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var interaction: PanelInteraction
    @Environment(\.colorScheme) private var colorScheme
    @State private var shelf: Shelf = .history
    @State private var query = ""
    @State private var kindFilter: ClipKind?
    @State private var sourceFilter: String?
    @State private var selectedID: UUID?
    @State private var previewEntry: ClipboardEntry?
    @State private var showSettings = false
    @State private var showBoardEditor = false
    @State private var editingBoard: Pinboard?
    @State private var boardName = ""
    @State private var boardColor: UInt32 = 0xF0646B
    @State private var boardError: String?
    @State private var boardToDelete: Pinboard?
    @State private var showClearConfirmation = false
    @State private var renamingEntry: ClipboardEntry?
    @State private var itemLabel = ""
    @State private var toast: String?
    @State private var toastToken = UUID()
    @State private var hoveredID: UUID?
    @FocusState private var searchFocused: Bool

    private var theme: PasteTheme { PasteTheme(colorScheme) }

    private var filteredEntries: [ClipboardEntry] {
        store.entries.filter { entry in
            let matchesShelf: Bool
            switch shelf {
            case .history: matchesShelf = true
            case .favorites: matchesShelf = entry.isPinned
            case .board(let id): matchesShelf = entry.pinboardIDs.contains(id)
            }
            return matchesShelf
                && (kindFilter == nil || entry.clipKind == kindFilter)
                && (sourceFilter == nil || entry.sourceApp == sourceFilter)
                && (query.isEmpty || entry.text.localizedStandardContains(query)
                    || entry.sourceApp.localizedStandardContains(query)
                    || (entry.label?.localizedStandardContains(query) ?? false))
        }
    }

    private var selected: ClipboardEntry? {
        filteredEntries.first(where: { $0.id == selectedID }) ?? filteredEntries.first
    }

    private var filterActive: Bool { kindFilter != nil || sourceFilter != nil }
    private var canPasteDirectly: Bool { interaction.directPasteEnabled && interaction.accessibilityGranted }

    var body: some View {
        let t = theme
        VStack(spacing: 0) {
            Capsule().fill(t.handleColor).frame(width: 34, height: 4).padding(.top, 9)
            toolbar(t)
            if store.clipboardAccessDenied || store.storageError != nil {
                Label(store.storageError ?? "Pano erişimi kapalı. macOS ayarlarından yapıştırma izni ver.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundColor(.orange).padding(.bottom, 7)
            }
            shelfBar(t)
            if filteredEntries.isEmpty {
                emptyState(t)
            } else {
                cards(t)
            }
            footer(t)
        }
        .foregroundColor(t.textPrimary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AdaptiveFrostedBackground(material: t.frostedMaterial))
        .background(t.panelBG)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(t.panelStroke, lineWidth: 0.5))
        .background(DrawerKeyboardHandler(onKey: handleKey))
        .onChange(of: interaction.presentationID) { _ in
            query = ""; kindFilter = nil; sourceFilter = nil; selectedID = nil; searchFocused = false; toast = nil
        }
        .onChange(of: query) { _ in selectedID = nil }
        .sheet(item: $previewEntry) { preview($0, t) }
        .sheet(isPresented: $showSettings) { settings(t) }
        .sheet(isPresented: $showBoardEditor) { boardEditor(t) }
        .sheet(item: $renamingEntry) { entry in labelEditor(entry, t) }
        .alert("Geçmiş temizlensin mi?", isPresented: $showClearConfirmation) {
            Button("Vazgeç", role: .cancel) { }
            Button("Temizle", role: .destructive) { store.clearHistory() }
        } message: { Text("Favorilerin ve koleksiyonlara eklediğin metinler korunur. Diğer metinler silinir.") }
        .alert("Koleksiyon kaldırılsın mı?", isPresented: Binding(get: { boardToDelete != nil }, set: { if !$0 { boardToDelete = nil } })) {
            Button("Vazgeç", role: .cancel) { boardToDelete = nil }
            Button("Kaldır", role: .destructive) {
                if let board = boardToDelete { if shelf == .board(board.id) { shelf = .history }; store.deletePinboard(board) }
                boardToDelete = nil
            }
        } message: { Text("Koleksiyon kaldırılır; içindeki metinler geçmişte kalır.") }
        .alert("İşlem tamamlanamadı", isPresented: Binding(get: { interaction.errorMessage != nil }, set: { if !$0 { interaction.errorMessage = nil } })) {
            Button("Tamam", role: .cancel) { interaction.errorMessage = nil }
        } message: { Text(interaction.errorMessage ?? "") }
    }

    // MARK: - Toolbar

    private func toolbar(_ t: PasteTheme) -> some View {
        HStack(spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: "clipboard.fill").font(.system(size: 16, weight: .semibold)).foregroundColor(t.accent)
                Text("pano").font(.system(size: 19, weight: .bold, design: .rounded)).tracking(-0.5)
            }.padding(.trailing, 4)
            searchBar(t)
            Spacer()
            HStack(spacing: 8) {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape").font(.system(size: 14)).frame(width: 28, height: 28).background(t.pillBG, in: Circle())
                }.buttonStyle(.plain).foregroundColor(t.textSecondary).help("Ayarlar").accessibilityLabel("Ayarlar")
                Button { interaction.dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 26, height: 26).background(t.pillBG, in: Circle())
                }.buttonStyle(.plain).foregroundColor(t.textSecondary).help("Kapat · Esc").accessibilityLabel("Pano'yu kapat")
            }
        }.padding(.horizontal, 22).frame(height: 54)
    }

    // MARK: - Search Bar

    private func searchBar(_ t: PasteTheme) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundColor(t.textTertiary)
            TextField("Ara…", text: $query).textFieldStyle(.plain).font(.system(size: 12)).focused($searchFocused)
                .accessibilityLabel("Pano geçmişinde ara").onSubmit { searchFocused = false }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundColor(t.textTertiary).accessibilityLabel("Aramayı temizle")
            }
            Menu {
                Section("İçerik türü") {
                    Button("Tüm türler") { kindFilter = nil; selectedID = nil }
                    ForEach(ClipKind.allCases) { kind in
                        Button { kindFilter = kind; selectedID = nil } label: {
                            Label(kind.title, systemImage: kindFilter == kind ? "checkmark" : kind.symbol)
                        }
                    }
                }
                Section("Kaynak uygulama") {
                    Button("Tüm uygulamalar") { sourceFilter = nil; selectedID = nil }
                    ForEach(Array(Set(store.entries.map(\.sourceApp))).sorted(), id: \.self) { source in
                        Button { sourceFilter = source; selectedID = nil } label: {
                            Label(source, systemImage: sourceFilter == source ? "checkmark" : "app")
                        }
                    }
                }
                if filterActive { Divider(); Button("Filtreleri temizle") { kindFilter = nil; sourceFilter = nil } }
            } label: {
                Image(systemName: filterActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                    .font(.system(size: 12)).foregroundColor(filterActive ? t.accent : t.textTertiary)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Arama filtreleri")
        }
        .padding(.horizontal, 11).frame(width: 220, height: 32)
        .background(t.searchBG, in: Capsule())
        .overlay(Capsule().stroke(searchFocused ? t.accent.opacity(0.6) : t.searchBorder, lineWidth: searchFocused ? 1.5 : 0.5))
    }

    // MARK: - Shelf Bar

    private func shelfBar(_ t: PasteTheme) -> some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    shelfPill(.history, title: "Geçmiş", icon: "clock.arrow.circlepath", color: nil, count: store.entries.count, t)
                    shelfPill(.favorites, title: "Favoriler", icon: "star.fill", color: 0xF5A623, count: store.entries.filter(\.isPinned).count, t)
                    ForEach(store.pinboards) { board in
                        shelfPill(.board(board.id), title: board.name, icon: nil, color: board.colorHex,
                                  count: store.entries.filter { $0.pinboardIDs.contains(board.id) }.count, t)
                            .contextMenu {
                                Button("Koleksiyonu düzenle…") { openBoardEditor(board) }
                                Button("Koleksiyonu kaldır…", role: .destructive) { boardToDelete = board }
                            }
                    }
                    Button { openBoardEditor(nil) } label: {
                        Image(systemName: "plus").font(.system(size: 11, weight: .medium)).foregroundColor(t.textTertiary)
                            .frame(width: 28, height: 28).background(t.pillBG, in: Circle())
                    }.buttonStyle(.plain).help("Yeni koleksiyon · ⇧⌘N").accessibilityLabel("Yeni koleksiyon")
                }.padding(.horizontal, 22)
            }.frame(height: 40)
            kindFilterBar(t)
        }
    }

    // MARK: - Kind Filter Bar

    private func kindFilterBar(_ t: PasteTheme) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                kindFilterPill(nil, label: "Tümü", symbol: "square.grid.2x2", color: t.textSecondary, t)
                ForEach(ClipKind.allCases) { kind in
                    kindFilterPill(kind, label: kind.title, symbol: kind.symbol, color: kind.tint, t)
                }
            }.padding(.horizontal, 22)
        }.frame(height: 36)
    }

    private func kindFilterPill(_ kind: ClipKind?, label: String, symbol: String, color: Color, _ t: PasteTheme) -> some View {
        let active = kindFilter == kind
        return Button {
            kindFilter = (active && kind != nil) ? nil : kind
            selectedID = nil
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(active ? color : t.textTertiary)
                Text(label)
                    .font(.system(size: 10, weight: active ? .semibold : .medium))
                    .foregroundColor(active ? t.textPrimary : t.textSecondary)
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(active ? color.opacity(0.15) : t.pillBG, in: Capsule())
            .overlay(Capsule().stroke(active ? color.opacity(0.4) : Color.clear, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private func shelfPill(_ target: Shelf, title: String, icon: String?, color: UInt32?, count: Int, _ t: PasteTheme) -> some View {
        Button {
            shelf = target; selectedID = nil; searchFocused = false
        } label: {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 11)).foregroundColor(color.map(Color.init(hex:)) ?? t.textSecondary) }
                else if let color { Circle().fill(Color(hex: color)).frame(width: 8, height: 8) }
                Text(title).font(.system(size: 11, weight: shelf == target ? .semibold : .medium)).lineLimit(1)
                if shelf == target { Text("\(count)").font(.system(size: 9, weight: .medium, design: .rounded)).foregroundColor(t.textTertiary) }
            }
            .padding(.horizontal, 11).frame(height: 28)
            .background(shelf == target ? t.pillActiveBG : t.pillBG, in: Capsule())
            .contentShape(Capsule())
        }.buttonStyle(.plain)
    }

    // MARK: - Cards

    private func cards(_ t: PasteTheme) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(Array(filteredEntries.enumerated()), id: \.element.id) { index, entry in
                        ClipboardCard(entry: entry, store: store, theme: t,
                                      selected: selected?.id == entry.id, hovered: hoveredID == entry.id,
                                      shortcut: index < 9 ? index + 1 : nil)
                        .frame(width: 200, height: 220)
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                        .scaleEffect(hoveredID == entry.id ? 1.03 : 1.0)
                        .animation(.easeOut(duration: 0.15), value: hoveredID)
                        .onHover { isHovered in hoveredID = isHovered ? entry.id : nil }
                        // Fix: use simultaneous gestures to avoid 350 ms double-tap wait
                        .gesture(
                            TapGesture(count: 2).onEnded { interaction.copyAndReturn(entry) }
                        )
                        .simultaneousGesture(
                            TapGesture(count: 1).onEnded { selectedID = entry.id; searchFocused = false }
                        )
                        .contextMenu { entryMenu(entry) }
                        .id(entry.id)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(entry.clipKind.title), \(entry.sourceApp), \(entry.cardTitle)")
                        .accessibilityAddTraits(selected?.id == entry.id ? [.isButton, .isSelected] : [.isButton])
                        .accessibilityAction { selectedID = entry.id }
                    }
                }.padding(.horizontal, 22).padding(.vertical, 6)
            }
            .onChange(of: selected?.id) { id in
                if let id { withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo(id, anchor: .center) } }
            }
            .onChange(of: interaction.presentationID) { _ in
                if let id = filteredEntries.first?.id { proxy.scrollTo(id, anchor: .leading) }
            }
        }
    }

    @ViewBuilder private func entryMenu(_ entry: ClipboardEntry) -> some View {
        Button(canPasteDirectly ? "Yapıştır" : "Kopyala ve önceki uygulamaya dön") { interaction.copyAndReturn(entry) }
        Button("Kopyala") { copyOnly(entry) }
        Button("Önizle") { previewEntry = entry }
        Divider()
        Button(entry.isPinned ? "Favorilerden çıkar" : "Favorilere ekle") { store.togglePin(entry) }
        Menu("Koleksiyona ekle") {
            ForEach(store.pinboards) { board in
                Button { store.toggleMembership(entry, in: board) } label: {
                    Label(board.name, systemImage: entry.pinboardIDs.contains(board.id) ? "checkmark.circle.fill" : "circle")
                }
            }
            if !store.pinboards.isEmpty { Divider() }
            Button("Yeni koleksiyon…") { openBoardEditor(nil) }
        }
        Button("Adlandır…") { itemLabel = entry.label ?? ""; renamingEntry = entry }
        Divider()
        Button("Sil", role: .destructive) { store.delete(entry) }
    }

    // MARK: - Footer

    private func footer(_ t: PasteTheme) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle().fill(store.isPaused ? Color.orange : Color(hex: 0x4BAE80)).frame(width: 5, height: 5)
                Text(store.isPaused ? "Duraklatıldı" : "\(filteredEntries.count) öğe")
                if filterActive {
                    Text("·"); Text([kindFilter?.title, sourceFilter].compactMap { $0 }.joined(separator: " · "))
                    Button { kindFilter = nil; sourceFilter = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("Tüm filtreleri temizle")
                }
            }
            Spacer()
            if let toast {
                Label(toast, systemImage: "checkmark.circle.fill").foregroundColor(t.accent)
            } else {
                keyHint("← →", "Gezin", t); keyHint("boşluk", "Önizle", t); keyHint("⌘ 1–9", "Hızlı seç", t)
            }
            Spacer()
            Button {
                if let selected { interaction.copyAndReturn(selected) }
            } label: {
                HStack(spacing: 7) {
                    Text(canPasteDirectly ? "Yapıştır" : "Kopyala").fontWeight(.semibold)
                    Text("↩").font(.system(size: 12, weight: .medium))
                }.padding(.horizontal, 14).frame(height: 26).foregroundColor(t.ctaFG).background(t.accent, in: Capsule())
            }.buttonStyle(.plain).disabled(selected == nil).opacity(selected == nil ? 0.35 : 1)
        }.font(.system(size: 10)).foregroundColor(t.textTertiary).padding(.horizontal, 22).frame(height: 44)
    }

    private func keyHint(_ key: String, _ title: String, _ t: PasteTheme) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.system(size: 9, weight: .medium, design: .monospaced))
                .padding(.horizontal, 5).padding(.vertical, 2).background(t.pillBG, in: RoundedRectangle(cornerRadius: 4))
            Text(title)
        }
    }

    // MARK: - Empty State

    private func emptyState(_ t: PasteTheme) -> some View {
        VStack(spacing: 12) {
            Image(systemName: emptyIcon).font(.system(size: 32, weight: .light)).foregroundColor(t.accent.opacity(0.5))
            Text(emptyTitle).font(.system(size: 17, weight: .semibold)).tracking(-0.3)
            Text(emptySubtitle).font(.system(size: 12)).foregroundColor(t.textTertiary)
            if store.isPaused && store.entries.isEmpty {
                Button("Kaydı sürdür") { store.isPaused = false }.buttonStyle(.borderedProminent).tint(t.accent)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyIcon: String {
        if !query.isEmpty || filterActive { return "magnifyingglass" }
        return shelf == .history ? "square.on.square" : "pin"
    }
    private var emptyTitle: String {
        if !query.isEmpty || filterActive { return "Aradığın metin burada yok." }
        return shelf == .history ? "Kopyaladığın her metin, bir kart." : "Buraya güzel şeyler biriktir."
    }
    private var emptySubtitle: String {
        if !query.isEmpty || filterActive { return "Başka bir kelime dene veya filtreleri temizle." }
        return shelf == .history ? "Herhangi bir metni ⌘C ile kopyala. Pano senin için saklasın." : "Geçmişteki bir karta sağ tıklayarak buraya ekleyebilirsin."
    }

    // MARK: - Preview

    private func preview(_ entry: ClipboardEntry, _ t: PasteTheme) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: entry.clipKind.symbol).foregroundColor(entry.clipKind.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.label ?? entry.clipKind.title).font(.system(size: 18, weight: .semibold))
                    Text(entry.sourceApp).font(.system(size: 11)).foregroundColor(.secondary)
                }
                Spacer()
                Button("Kapat") { previewEntry = nil }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                if entry.clipKind == .image, let image = store.loadImage(for: entry) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Text(entry.text).font(.system(size: 14, design: entry.clipKind == .code ? .monospaced : .default))
                        .lineSpacing(6).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(18)
                }
            }.frame(height: 280).background(t.previewBG, in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Text("\(entry.text.count) karakter · \(entry.copiedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                Spacer()
                Button("Kopyala") { copyOnly(entry) }.buttonStyle(.borderedProminent).tint(t.accent)
            }
        }.padding(26).frame(width: 620)
    }

    // MARK: - Settings

    private func settings(_ t: PasteTheme) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Pano ayarları").font(.system(size: 23, weight: .semibold))
                Spacer()
                Button("Bitti") { showSettings = false }.keyboardShortcut(.cancelAction)
            }
            Toggle("Kopyaladığım metinleri kaydet", isOn: Binding(get: { !store.isPaused }, set: { store.isPaused = !$0 }))
                .toggleStyle(.switch).tint(t.accent)
            Divider()
            VStack(alignment: .leading, spacing: 9) {
                Label("Doğrudan yapıştırma", systemImage: "arrow.up.doc.on.clipboard").font(.system(size: 13, weight: .semibold))
                Text("Enter veya çift tıklama ile seçtiğin metni önceki uygulamaya yapıştır.")
                    .font(.system(size: 12)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                if canPasteDirectly {
                    Toggle("Doğrudan yapıştır", isOn: $interaction.directPasteEnabled).toggleStyle(.switch).tint(t.accent)
                } else {
                    Button(interaction.directPasteEnabled ? "Erişilebilirlik iznini aç" : "Yapıştırmayı etkinleştir") { interaction.requestAccessibility() }
                    Text("İzin verilene kadar metin kopyalanır; ⌘V ile yapıştırabilirsin.").font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                Label("Sadece bu Mac'te", systemImage: "lock.shield").font(.system(size: 13, weight: .semibold))
                Text("Son 200 metin ve resim saklanır. Verilerin internete gönderilmez.")
                    .font(.system(size: 12)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Geçmişi temizle…") { showSettings = false; showClearConfirmation = true }
                Spacer()
                Text(interaction.shortcutAvailable ? "Aç / kapat  ⌘⇧V" : "Menü çubuğundan aç").font(.system(size: 11)).foregroundColor(.secondary)
            }
        }.padding(28).frame(width: 480)
    }

    // MARK: - Board Editor

    private func boardEditor(_ t: PasteTheme) -> some View {
        VStack(alignment: .leading, spacing: 19) {
            Text(editingBoard == nil ? "Yeni koleksiyon" : "Koleksiyonu düzenle").font(.system(size: 21, weight: .semibold))
            Text("Sık kullandığın metinleri bir arada tut.").font(.system(size: 12)).foregroundColor(.secondary)
            TextField("Örn. İş, Fikirler, Hazır yanıtlar", text: $boardName).textFieldStyle(.roundedBorder).onSubmit { saveBoard() }
            HStack(spacing: 13) {
                ForEach(PasteTheme.boardColors, id: \.self) { color in
                    Button { boardColor = color } label: {
                        Circle().fill(Color(hex: color)).frame(width: 25, height: 25)
                            .overlay { if boardColor == color { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundColor(.white) } }
                    }.buttonStyle(.plain).accessibilityLabel("Renk \(String(color, radix: 16))")
                }
            }
            if let boardError { Text(boardError).font(.system(size: 11)).foregroundColor(.red) }
            HStack {
                Spacer()
                Button("Vazgeç") { showBoardEditor = false }.keyboardShortcut(.cancelAction)
                Button("Kaydet") { saveBoard() }.buttonStyle(.borderedProminent).tint(t.accent).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 390)
    }

    private func labelEditor(_ entry: ClipboardEntry, _ t: PasteTheme) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Karta bir ad ver").font(.system(size: 21, weight: .semibold))
            TextField("Kart adı", text: $itemLabel).textFieldStyle(.roundedBorder)
            Text("İçerik aynı kalır. Boş bırakırsan otomatik başlık kullanılır.").font(.system(size: 11)).foregroundColor(.secondary)
            HStack {
                Spacer()
                Button("Vazgeç") { renamingEntry = nil }.keyboardShortcut(.cancelAction)
                Button("Kaydet") { store.setLabel(entry, label: itemLabel); renamingEntry = nil }
                    .buttonStyle(.borderedProminent).tint(t.accent).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 420)
    }

    // MARK: - Helpers

    private func openBoardEditor(_ board: Pinboard?) {
        editingBoard = board; boardName = board?.name ?? ""
        boardColor = board?.colorHex ?? PasteTheme.boardColors[store.pinboards.count % PasteTheme.boardColors.count]
        boardError = nil; showBoardEditor = true
    }

    private func saveBoard() {
        if let board = editingBoard {
            guard store.renamePinboard(board, name: boardName) else { boardError = "1–40 karakter arasında, benzersiz bir ad kullan."; return }
            store.setPinboardColor(board, colorHex: boardColor)
        } else {
            guard let board = store.createPinboard(name: boardName, colorHex: boardColor) else { boardError = "1–40 karakter arasında, benzersiz bir ad kullan."; return }
            shelf = .board(board.id)
        }
        showBoardEditor = false
    }

    private func copyOnly(_ entry: ClipboardEntry) {
        guard store.copy(entry) else { interaction.errorMessage = "Panoya kopyalanamadı."; return }
        selectedID = entry.id; toast = "Panoya kopyalandı"
        let token = UUID(); toastToken = token
        Task { @MainActor in try? await Task.sleep(nanoseconds: 1_800_000_000); if toastToken == token { toast = nil } }
    }

    private func moveSelection(_ offset: Int) {
        let entries = filteredEntries; guard !entries.isEmpty else { return }
        let index = entries.firstIndex(where: { $0.id == selected?.id }) ?? 0
        selectedID = entries[min(max(index + offset, 0), entries.count - 1)].id
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard !showSettings, !showBoardEditor, previewEntry == nil, renamingEntry == nil,
              !showClearConfirmation, boardToDelete == nil, interaction.errorMessage == nil else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = modifiers.contains(.command)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if command {
            if key == "f" { searchFocused = true; return true }
            if key == "," { showSettings = true; return true }
            if key == "n" && modifiers.contains(.shift) { openBoardEditor(nil); return true }
            if key == "t" { store.isPaused.toggle(); return true }
            if let number = Int(key), (1...9).contains(number), number <= filteredEntries.count {
                interaction.copyAndReturn(filteredEntries[number - 1]); return true
            }
            if key == "c" && !searchFocused, let selected { copyOnly(selected); return true }
            return false
        }
        if modifiers.contains(.control) || modifiers.contains(.option) { return false }
        switch event.keyCode {
        case 53:
            if !query.isEmpty || filterActive { query = ""; kindFilter = nil; sourceFilter = nil; searchFocused = false }
            else { interaction.dismiss() }; return true
        case 36, 76:
            if searchFocused { searchFocused = false } else if let selected { interaction.copyAndReturn(selected) }; return true
        case 48: searchFocused.toggle(); return true
        case 125: searchFocused = false; return true
        case 123 where !searchFocused: moveSelection(-1); return true
        case 124 where !searchFocused: moveSelection(1); return true
        case 49 where !searchFocused: previewEntry = selected; return true
        case 51 where !searchFocused, 117 where !searchFocused: if let selected { store.delete(selected) }; return true
        default: break
        }
        if !searchFocused, let characters = event.characters, !characters.isEmpty,
           characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) {
            query += characters; searchFocused = true; return true
        }
        return false
    }
}

// MARK: - Clipboard Card

private struct ClipboardCard: View {
    let entry: ClipboardEntry
    let store: ClipboardStore
    let theme: PasteTheme
    let selected: Bool
    let hovered: Bool
    let shortcut: Int?

    private var kind: ClipKind { entry.clipKind }

    // Vibrant per-type header colors (matching Paste app palette)
    private var headerColor: Color {
        switch kind {
        case .text:  return Color(hex: 0x3B82F6)   // blue
        case .link:  return Color(hex: 0x10B981)   // emerald
        case .code:  return Color(hex: 0x8B5CF6)   // violet
        case .color: return Color(hex: 0xF59E0B)   // amber
        case .image: return Color(hex: 0xEF4444)   // red
        }
    }

    var body: some View {
        let t = theme
        VStack(spacing: 0) {
            // ── Colored header strip ──────────────────────────────
            cardHeader(t)
            // ── Content body ─────────────────────────────────────
            cardBody(t)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            // ── Footer: metadata + shortcut ───────────────────────
            cardFooter(t)
        }
        .frame(width: 200, height: 220)
        .background(t.cardBG)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(selected ? headerColor : (hovered ? t.cardHoverBorder : t.cardBorder),
                        lineWidth: selected ? 2 : 0.5)
        )
        .shadow(color: selected ? headerColor.opacity(0.25) : t.cardShadow,
                radius: selected ? 10 : 4, y: selected ? 4 : 2)
    }

    // MARK: Header
    @ViewBuilder private func cardHeader(_ t: PasteTheme) -> some View {
        ZStack {
            // Gradient background
            LinearGradient(
                colors: [headerColor, headerColor.opacity(0.80)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Image(systemName: kind.symbol)
                            .font(.system(size: 10, weight: .semibold))
                        Text(entry.label ?? kind.title)
                            .font(.system(size: 11, weight: .bold))
                            .lineLimit(1)
                    }
                    TimelineView(.periodic(from: .now, by: 60)) { _ in
                        Text(entry.relativeTime)
                            .font(.system(size: 9))
                            .opacity(0.80)
                    }
                }
                .foregroundColor(.white)
                .padding(.leading, 12)
                Spacer(minLength: 6)
                // Source app icon — right side of header
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.20))
                        .frame(width: 28, height: 28)
                    SourceAppIcon(bundleID: entry.sourceBundleIdentifier,
                                  fallback: kind.symbol)
                        .frame(width: 18, height: 18)
                }
                .padding(.trailing, 10)
            }
        }
        .frame(height: 52)
    }

    // MARK: Body
    @ViewBuilder private func cardBody(_ t: PasteTheme) -> some View {
        switch kind {
        case .image:
            if let image = store.loadImage(for: entry) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.system(size: 26, weight: .ultraLight))
                        .foregroundColor(t.textTertiary)
                    Text("Resim yüklenmedi")
                        .font(.system(size: 10))
                        .foregroundColor(t.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(t.previewBG)
            }

        case .color:
            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(hex: entry.colorValue ?? 0))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .shadow(color: Color(hex: entry.colorValue ?? 0).opacity(0.4), radius: 6, y: 3)
                Text(entry.text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundColor(t.colorLabel)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        case .link:
            VStack(alignment: .leading, spacing: 7) {
                Text(entry.cardTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(t.textPrimary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(entry.text)
                    .font(.system(size: 9))
                    .foregroundColor(t.textTertiary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        case .code:
            ScrollView(.vertical, showsIndicators: false) {
                Text(entry.text.prefix(600))
                    .font(.system(size: 9.5, design: .monospaced))
                    .lineSpacing(3)
                    .foregroundColor(t.codeColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }

        case .text:
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.text.prefix(400))
                    .font(.system(size: 11.5))
                    .lineSpacing(4)
                    .foregroundColor(t.textSecondary)
                    .lineLimit(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: Footer
    @ViewBuilder private func cardFooter(_ t: PasteTheme) -> some View {
        HStack(spacing: 0) {
            // Metadata (char count / image size)
            Group {
                if kind == .image, let img = store.loadImage(for: entry) {
                    let w = Int(img.size.width), h = Int(img.size.height)
                    Text("\(w) × \(h)")
                } else if kind != .image {
                    Text("\(entry.text.count) karakter")
                } else {
                    Text("")
                }
            }
            .font(.system(size: 9, design: .rounded))
            .foregroundColor(t.textTertiary)
            .padding(.leading, 12)

            Spacer(minLength: 4)

            // Pin / Board indicators
            if entry.isPinned {
                Image(systemName: "star.fill")
                    .font(.system(size: 8))
                    .foregroundColor(Color(hex: 0xF5A623))
                    .padding(.trailing, 4)
            }
            if !entry.pinboardIDs.isEmpty {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8))
                    .foregroundColor(t.textTertiary)
                    .padding(.trailing, 4)
            }

            // ⌘N shortcut badge
            if let shortcut {
                Text("⌘\(shortcut)")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(headerColor.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
                    .padding(.trailing, 10)
            } else {
                Spacer().frame(width: 10)
            }
        }
        .frame(height: 32)
        .background(t.cardBG)
        .overlay(alignment: .top) {
            Divider().opacity(0.5)
        }
    }
}




// MARK: - Source App Icon

private struct SourceAppIcon: View {
    let bundleID: String?
    let fallback: String
    var body: some View {
        Group {
            if let icon = AppIconCache.icon(for: bundleID) {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Image(systemName: fallback).font(.system(size: 10, weight: .light))
            }
        }.frame(width: 14, height: 14)
    }
}

// MARK: - Adaptive Frosted Background

private struct AdaptiveFrostedBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

// MARK: - Keyboard Handler

private struct DrawerKeyboardHandler: NSViewRepresentable {
    var onKey: (NSEvent) -> Bool
    func makeCoordinator() -> Coordinator { Coordinator(onKey: onKey) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator = context.coordinator] event in
            guard let coordinator, let window = coordinator.view?.window,
                  event.window === window, window.isKeyWindow, window.attachedSheet == nil else { return event }
            return coordinator.onKey(event) ? nil : event
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.onKey = onKey }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }
    class Coordinator {
        weak var view: NSView?
        var monitor: Any?
        var onKey: (NSEvent) -> Bool
        init(onKey: @escaping (NSEvent) -> Bool) { self.onKey = onKey }
    }
}
