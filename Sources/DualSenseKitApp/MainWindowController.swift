import AppKit
import DualSenseKitRuntime

@MainActor
final class MainWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private enum Page {
        case mapping
        case hooks
        case settings
    }

    private let configStore: ConfigStore
    private let profileStore: ProfileStore
    private let hookStore: HookStore
    private let hookService: HookService
    private let preferences: AppPreferences
    private let onPreferencesChanged: () -> Void

    private var config: BridgeConfig
    private var editingProfile: MappingProfile = MappingProfile(name: "默认", mappings: [:])
    private var editingProfileID: UUID?
    private var slotViews: [ControllerButton: ButtonSlotView] = [:]
    private var activePopover: NSPopover?
    private var hooks: [HookDefinition]
    private var currentPage: Page = .mapping
    private var selectedButton: ControllerButton = .dpadRight
    private var capturedStroke: KeyStroke?
    private var keyMonitor: Any?
    private var selectedApplicationPath: String?
    private var editingHookID: UUID?
    private var editingCommandID: UUID?
    private var hookDetailIndex: Int?

    private let sidebar = NSView()
    private let contentContainer = NSView()
    private let mappingNavButton = NSButton(title: "按键映射", target: nil, action: nil)
    private let hooksNavButton = NSButton(title: "Hook 配置", target: nil, action: nil)
    private let settingsNavButton = NSButton(title: "设置", target: nil, action: nil)
    private let launchCheck = NSButton(checkboxWithTitle: "开机自启", target: nil, action: nil)
    private let dockCheck = NSButton(checkboxWithTitle: "Dock 图标", target: nil, action: nil)
    private let statusCheck = NSButton(checkboxWithTitle: "状态栏图标", target: nil, action: nil)
    private let profilePopup = NSPopUpButton(frame: .zero, pullsDown: false)

    private let previewView = ControllerPreviewView()
    private let selectedTitle = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let advancedLabel = NSTextField(labelWithString: "")
    private let gesturePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let actionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let keyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let commandCheck = NSButton(checkboxWithTitle: "Command", target: nil, action: nil)
    private let optionCheck = NSButton(checkboxWithTitle: "Option", target: nil, action: nil)
    private let controlCheck = NSButton(checkboxWithTitle: "Control", target: nil, action: nil)
    private let shiftCheck = NSButton(checkboxWithTitle: "Shift", target: nil, action: nil)
    private let recordButton = NSButton(title: "录制快捷键", target: nil, action: nil)
    private let clearButton = NSButton(title: "清空绑定", target: nil, action: nil)
    private let saveButton = NSButton(title: "保存绑定", target: nil, action: nil)
    private let chooseAppButton = NSButton(title: "选择 App", target: nil, action: nil)
    private let appPathLabel = NSTextField(labelWithString: "未选择应用")

    private let hookTable = NSTableView()
    private let commandTable = NSTableView()
    private let hookNameField = NSTextField()
    private let hookSlugField = NSTextField()
    private let hookEnabledCheck = NSButton(checkboxWithTitle: "启用", target: nil, action: nil)
    private let hookURLField = NSTextField()
    private let addCommandPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let commandKindPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let hookStopChannelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let hookColorAWell = NSColorWell()
    private let hookColorBWell = NSColorWell()
    private let hookBrightnessField = NSTextField()
    private let hookIntervalField = NSTextField()
    private let hookDurationField = NSTextField()
    private let hookStrengthField = NSTextField()
    private let hookPlayerMaskField = NSTextField()
    private let hookPlayerBrightnessPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let hookResetCheck = NSButton(checkboxWithTitle: "停止时复位灯光和震动", target: nil, action: nil)
    private let hookStatusLabel = NSTextField(labelWithString: "")

    init(
        configStore: ConfigStore,
        profileStore: ProfileStore,
        hookStore: HookStore,
        hookService: HookService,
        preferences: AppPreferences,
        onPreferencesChanged: @escaping () -> Void
    ) {
        self.configStore = configStore
        self.profileStore = profileStore
        self.hookStore = hookStore
        self.hookService = hookService
        self.preferences = preferences
        self.onPreferencesChanged = onPreferencesChanged
        self.config = configStore.current
        self.hooks = hookStore.hooks
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "DualSense Bridge"
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 920, height: 580)
        super.init(window: window)
        buildContent()
        reloadFromStore()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func reloadFromStore() {
        config = configStore.current
        hooks = hookStore.load()
        let stored = profileStore.profiles.first(where: { $0.id == editingProfileID })
            ?? profileStore.defaultProfile()
        editingProfileID = stored.id
        editingProfile = stored
        selectedButton = editingProfile.mappings.keys.first?.button ?? .dpadRight
        previewView.selectedButton = selectedButton
        hookTable.reloadData()
        if hookTable.selectedRow < 0 && !hooks.isEmpty {
            hookTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        loadSelection()
        loadSelectedHook()
        loadPreferences()
        show(page: currentPage)
    }

    private func buildContent() {
        guard let window else { return }
        let sidebarBg = NSColor(calibratedRed: 0.062, green: 0.078, blue: 0.114, alpha: 1)
        let contentBg = NSColor(calibratedRed: 0.090, green: 0.108, blue: 0.152, alpha: 1)

        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = contentBg.cgColor
        root.translatesAutoresizingMaskIntoConstraints = false

        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = sidebarBg.cgColor
        let sidebarContent = buildSidebar()
        sidebar.addSubview(sidebarContent)

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.wantsLayer = true
        contentContainer.layer?.backgroundColor = contentBg.cgColor

        let sep = NSView()
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor(white: 1, alpha: 0.06).cgColor
        sep.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(sidebar)
        root.addSubview(sep)
        root.addSubview(contentContainer)
        window.contentView = root
        NSLayoutConstraint.activate([
            sidebarContent.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            sidebarContent.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            sidebarContent.topAnchor.constraint(equalTo: sidebar.topAnchor),
            sidebarContent.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 256),
            sep.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            sep.topAnchor.constraint(equalTo: root.topAnchor),
            sep.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sep.widthAnchor.constraint(equalToConstant: 1),
            contentContainer.leadingAnchor.constraint(equalTo: sep.trailingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: root.topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
    }

    private func buildSidebar() -> NSView {
        let cardBg = NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.19, alpha: 1)
        let accentBlue = NSColor(calibratedRed: 0.22, green: 0.52, blue: 0.95, alpha: 1)
        let W: CGFloat = 222

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 17, bottom: 22, right: 17)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // --- Brand row ---
        let iconView = NSImageView()
        let iconCfg = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        iconView.image = NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: nil)
        iconView.symbolConfiguration = iconCfg
        iconView.contentTintColor = accentBlue
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 22).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 22).isActive = true

        let appTitle = NSTextField(labelWithString: "DualSense Bridge")
        appTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        appTitle.textColor = .white

        let brandStack = NSStackView(views: [iconView, appTitle])
        brandStack.orientation = .horizontal
        brandStack.alignment = .centerY
        brandStack.spacing = 8
        brandStack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(brandStack)
        stack.setCustomSpacing(18, after: brandStack)

        // --- Device card ---
        let deviceSectionLabel = sidebarSectionHeader("DEVICE")
        stack.addArrangedSubview(deviceSectionLabel)
        stack.setCustomSpacing(8, after: deviceSectionLabel)

        let deviceCard = NSView()
        deviceCard.wantsLayer = true
        deviceCard.layer?.backgroundColor = cardBg.cgColor
        deviceCard.layer?.cornerRadius = 10
        deviceCard.translatesAutoresizingMaskIntoConstraints = false
        deviceCard.widthAnchor.constraint(equalToConstant: W).isActive = true

        let deviceName = NSTextField(labelWithString: "DualSense")
        deviceName.font = .systemFont(ofSize: 13, weight: .semibold)
        deviceName.textColor = .white
        deviceName.lineBreakMode = .byTruncatingTail

        let dotView = NSView()
        dotView.wantsLayer = true
        dotView.layer?.backgroundColor = NSColor(calibratedRed: 0.15, green: 0.85, blue: 0.42, alpha: 1).cgColor
        dotView.layer?.cornerRadius = 4
        dotView.translatesAutoresizingMaskIntoConstraints = false
        dotView.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dotView.heightAnchor.constraint(equalToConstant: 8).isActive = true

        let connectedLabel = NSTextField(labelWithString: "Connected")
        connectedLabel.font = .systemFont(ofSize: 11, weight: .medium)
        connectedLabel.textColor = NSColor(calibratedRed: 0.15, green: 0.85, blue: 0.42, alpha: 1)

        let connectedRow = NSStackView(views: [dotView, connectedLabel])
        connectedRow.orientation = .horizontal
        connectedRow.alignment = .centerY
        connectedRow.spacing = 5

        let controllerThumb = NSImageView()
        if let url = Bundle.module.url(forResource: "dualsense-controller", withExtension: "svg"),
           let img = NSImage(contentsOf: url) {
            controllerThumb.image = img
        } else {
            let bigIconCfg = NSImage.SymbolConfiguration(pointSize: 36, weight: .thin)
            controllerThumb.image = NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: nil)
            controllerThumb.symbolConfiguration = bigIconCfg
            controllerThumb.contentTintColor = NSColor(white: 0.30, alpha: 1)
        }
        controllerThumb.imageScaling = .scaleProportionallyDown
        controllerThumb.translatesAutoresizingMaskIntoConstraints = false
        controllerThumb.widthAnchor.constraint(equalToConstant: 72).isActive = true
        controllerThumb.heightAnchor.constraint(equalToConstant: 44).isActive = true

        let infoStack = NSStackView()
        infoStack.orientation = .vertical
        infoStack.alignment = .leading
        infoStack.spacing = 5
        infoStack.translatesAutoresizingMaskIntoConstraints = false
        infoStack.addArrangedSubview(deviceName)
        infoStack.addArrangedSubview(connectedRow)

        let cardContent = NSStackView(views: [infoStack, controllerThumb])
        cardContent.orientation = .horizontal
        cardContent.alignment = .centerY
        cardContent.spacing = 8
        cardContent.translatesAutoresizingMaskIntoConstraints = false

        deviceCard.addSubview(cardContent)
        NSLayoutConstraint.activate([
            cardContent.leadingAnchor.constraint(equalTo: deviceCard.leadingAnchor, constant: 12),
            cardContent.trailingAnchor.constraint(equalTo: deviceCard.trailingAnchor, constant: -12),
            cardContent.topAnchor.constraint(equalTo: deviceCard.topAnchor, constant: 12),
            cardContent.bottomAnchor.constraint(equalTo: deviceCard.bottomAnchor, constant: -12)
        ])

        stack.addArrangedSubview(deviceCard)
        stack.setCustomSpacing(20, after: deviceCard)

        // --- Controls navigation ---
        let controlsSectionLabel = sidebarSectionHeader("CONTROLS")
        stack.addArrangedSubview(controlsSectionLabel)
        stack.setCustomSpacing(4, after: controlsSectionLabel)

        styleDarkNavButton(mappingNavButton, title: "按键映射", symbolName: "arrow.left.arrow.right", width: W)
        styleDarkNavButton(hooksNavButton, title: "Hook 配置", symbolName: "link", width: W)
        mappingNavButton.target = self
        mappingNavButton.action = #selector(showMappingPage)
        hooksNavButton.target = self
        hooksNavButton.action = #selector(showHooksPage)
        stack.addArrangedSubview(mappingNavButton)
        stack.setCustomSpacing(2, after: mappingNavButton)
        stack.addArrangedSubview(hooksNavButton)

        let flexSpacer = NSView()
        flexSpacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        flexSpacer.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(flexSpacer)

        let sepLine = NSView()
        sepLine.wantsLayer = true
        sepLine.layer?.backgroundColor = NSColor(white: 1, alpha: 0.07).cgColor
        sepLine.translatesAutoresizingMaskIntoConstraints = false
        sepLine.widthAnchor.constraint(equalToConstant: W).isActive = true
        sepLine.heightAnchor.constraint(equalToConstant: 1).isActive = true
        stack.addArrangedSubview(sepLine)
        stack.setCustomSpacing(6, after: sepLine)

        styleDarkNavButton(settingsNavButton, title: "设置", symbolName: "gear", width: W)
        settingsNavButton.target = self
        settingsNavButton.action = #selector(showSettingsPage)
        stack.addArrangedSubview(settingsNavButton)

        [launchCheck, dockCheck, statusCheck].forEach {
            $0.target = self
            $0.action = #selector(preferencesChanged)
            $0.font = .systemFont(ofSize: 13, weight: .regular)
            $0.contentTintColor = .labelColor
        }

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    private func sidebarSectionHeader(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = NSColor(white: 0.40, alpha: 1)
        return label
    }

    private func styleDarkNavButton(_ button: NSButton, title: String, symbolName: String, width: CGFloat) {
        button.title = "  \(title)"
        let imgCfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(imgCfg)
        button.imagePosition = .imageLeft
        button.imageHugsTitle = true
        button.alignment = .left
        button.isBordered = false
        button.font = .systemFont(ofSize: 13, weight: .medium)
        button.contentTintColor = NSColor(white: 0.65, alpha: 1)
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        button.translatesAutoresizingMaskIntoConstraints = false
        button.constraints.filter { $0.firstAttribute == .width || $0.firstAttribute == .height }.forEach { $0.isActive = false }
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        button.heightAnchor.constraint(equalToConstant: 36).isActive = true
    }

    @objc private func showMappingPage() {
        show(page: .mapping)
    }

    @objc private func showHooksPage() {
        hookDetailIndex = nil
        show(page: .hooks)
    }

    @objc private func showSettingsPage() {
        show(page: .settings)
    }

    private func show(page: Page) {
        currentPage = page
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        let pageView: NSView
        switch page {
        case .mapping:
            pageView = buildMappingPage()
        case .hooks:
            pageView = buildHooksPage()
        case .settings:
            pageView = buildSettingsPage()
        }
        pageView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(pageView)
        NSLayoutConstraint.activate([
            pageView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            pageView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            pageView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            pageView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
        ])
        mappingNavButton.state = page == .mapping ? .on : .off
        hooksNavButton.state = page == .hooks ? .on : .off
        settingsNavButton.state = page == .settings ? .on : .off
        styleSidebarSelection()
        if page == .hooks {
            loadSelectedHook()
        }
    }

    private func styleSidebarSelection() {
        let selectedBg = NSColor(calibratedRed: 0.14, green: 0.20, blue: 0.32, alpha: 1)
        let selectedTint = NSColor.white
        let normalTint = NSColor(white: 0.62, alpha: 1)
        [(mappingNavButton, Page.mapping), (hooksNavButton, Page.hooks), (settingsNavButton, Page.settings)].forEach { button, page in
            button.layer?.backgroundColor = currentPage == page ? selectedBg.cgColor : NSColor.clear.cgColor
            button.contentTintColor = currentPage == page ? selectedTint : normalTint
        }
    }

    private func buildMappingPage() -> NSView {
        slotViews = [:]
        activePopover?.close()
        activePopover = nil

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedRed: 0.090, green: 0.108, blue: 0.152, alpha: 1).cgColor

        // Header
        let titleLabel = NSTextField(labelWithString: "Button Remapping")
        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let subtitleLabel = NSTextField(labelWithString: "Choose replacement targets for controller button slots.")
        subtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = NSColor(white: 0.55, alpha: 1)
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        // Profile toolbar
        reloadProfilePopup()
        profilePopup.target = self
        profilePopup.action = #selector(profileSelectionChanged)
        profilePopup.controlSize = .regular
        profilePopup.translatesAutoresizingMaskIntoConstraints = false
        profilePopup.widthAnchor.constraint(equalToConstant: 180).isActive = true

        let bindAppBtn = NSButton(title: "绑定应用", target: self, action: #selector(bindProfileToApp))
        let renameBtn  = NSButton(title: "重命名", target: self, action: #selector(renameProfile))
        let saveProfBtn = NSButton(title: "保存", target: self, action: #selector(saveMappingProfile))
        let saveNewBtn = NSButton(title: "另存为", target: self, action: #selector(saveNewProfile))
        let deleteProfBtn = NSButton(title: "删除配置", target: self, action: #selector(deleteCurrentProfile))
        [bindAppBtn, renameBtn, saveProfBtn, saveNewBtn, deleteProfBtn].forEach { styleSmallDarkButton($0) }
        deleteProfBtn.isEnabled = !editingProfile.isDefault

        let profileBar = NSStackView(views: [profilePopup, bindAppBtn, flexSpacer(), renameBtn, saveProfBtn, saveNewBtn, deleteProfBtn])
        profileBar.orientation = .horizontal
        profileBar.alignment = .centerY
        profileBar.spacing = 8
        profileBar.translatesAutoresizingMaskIntoConstraints = false

        // Slot columns
        let leftButtons: [ControllerButton] = [.leftTrigger, .leftShoulder, .leftThumbstickButton, .buttonMenu,
                                                .dpadUp, .dpadLeft, .dpadDown, .dpadRight]
        let rightButtons: [ControllerButton] = [.rightTrigger, .rightShoulder, .rightThumbstickButton, .buttonOptions,
                                                 .buttonY, .buttonB, .buttonA, .buttonX]
        let centerButtons: [ControllerButton] = [.buttonHome, .buttonMicrophoneMute, .touchpadButton]

        let leftStack = makeSlotColumn(buttons: leftButtons)
        let rightStack = makeSlotColumn(buttons: rightButtons)

        // Controller image
        let controllerImage = NSImageView()
        if let url = Bundle.module.url(forResource: "dualsense-controller", withExtension: "svg"),
           let img = NSImage(contentsOf: url) {
            controllerImage.image = img
        } else {
            let cfg = NSImage.SymbolConfiguration(pointSize: 80, weight: .thin)
            controllerImage.image = NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: nil)
            controllerImage.symbolConfiguration = cfg
            controllerImage.contentTintColor = NSColor(white: 0.35, alpha: 1)
        }
        controllerImage.imageScaling = .scaleProportionallyDown
        controllerImage.translatesAutoresizingMaskIntoConstraints = false

        let slotsRow = NSStackView(views: [leftStack, controllerImage, rightStack])
        slotsRow.orientation = .horizontal
        slotsRow.alignment = .centerY
        slotsRow.spacing = 12
        slotsRow.translatesAutoresizingMaskIntoConstraints = false
        leftStack.widthAnchor.constraint(equalToConstant: 190).isActive = true
        rightStack.widthAnchor.constraint(equalToConstant: 190).isActive = true

        // Center row
        let centerRow = NSStackView()
        centerRow.orientation = .horizontal
        centerRow.alignment = .centerY
        centerRow.spacing = 12
        centerRow.translatesAutoresizingMaskIntoConstraints = false
        for btn in centerButtons {
            centerRow.addArrangedSubview(makeSlotView(button: btn))
        }

        root.addSubview(titleLabel)
        root.addSubview(subtitleLabel)
        root.addSubview(profileBar)
        root.addSubview(slotsRow)
        root.addSubview(centerRow)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),

            profileBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            profileBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            profileBar.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 14),

            slotsRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            slotsRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            slotsRow.topAnchor.constraint(equalTo: profileBar.bottomAnchor, constant: 16),

            controllerImage.heightAnchor.constraint(equalTo: controllerImage.widthAnchor,
                                                     multiplier: 429.39 / 597.47),

            centerRow.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            centerRow.topAnchor.constraint(equalTo: slotsRow.bottomAnchor, constant: 10),
            centerRow.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -16)
        ])

        return root
    }

    private func makeSlotColumn(buttons: [ControllerButton]) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        for btn in buttons {
            stack.addArrangedSubview(makeSlotView(button: btn))
        }
        return stack
    }

    private func makeSlotView(button: ControllerButton) -> ButtonSlotView {
        let glyph = loadGlyph(for: button)
        let slot = ButtonSlotView(button: button, glyphImage: glyph)
        slot.updateSummary(slotSummary(for: button))
        slot.onChevronClicked = { [weak self, weak slot] in
            guard let self, let slot else { return }
            self.showBindingPopover(for: button, from: slot)
        }
        slotViews[button] = slot
        return slot
    }

    private func slotSummary(for button: ControllerButton) -> String {
        let priority: [PressKind] = [.press, .singleClick, .doubleClick, .longPress, .release]
        for kind in priority {
            let actions = editingProfile.mappings[ButtonGesture(button: button, kind: kind)] ?? []
            if !actions.isEmpty { return summaryText(for: actions) }
        }
        return "未绑定"
    }

    private func reloadSlotSummaries() {
        for (button, slot) in slotViews {
            slot.updateSummary(slotSummary(for: button))
        }
    }

    private func showBindingPopover(for button: ControllerButton, from anchor: NSView) {
        activePopover?.close()
        let editor = BindingEditorController()
        editor.controllerButton = button
        editor.profileMappings = editingProfile.mappings
        editor.onBindingChanged = { [weak self] gesture, actions in
            guard let self else { return }
            if let actions {
                self.editingProfile.mappings[gesture] = actions
            } else {
                self.editingProfile.mappings.removeValue(forKey: gesture)
            }
            self.profileStore.upsert(self.editingProfile)
            self.slotViews[gesture.button]?.updateSummary(self.slotSummary(for: gesture.button))
        }
        let pop = NSPopover()
        pop.contentViewController = editor
        pop.behavior = .semitransient
        pop.contentSize = NSSize(width: 360, height: 330)
        pop.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        activePopover = pop
    }

    private func reloadProfilePopup() {
        profilePopup.removeAllItems()
        for profile in profileStore.profiles {
            profilePopup.addItem(withTitle: profile.name)
            profilePopup.lastItem?.representedObject = profile.id
        }
        if let id = editingProfileID {
            for index in 0..<profilePopup.numberOfItems {
                if profilePopup.item(at: index)?.representedObject as? UUID == id {
                    profilePopup.selectItem(at: index)
                    break
                }
            }
        }
    }

    @objc private func profileSelectionChanged() {
        guard let id = profilePopup.selectedItem?.representedObject as? UUID,
              let profile = profileStore.profiles.first(where: { $0.id == id }) else { return }
        editingProfileID = id
        editingProfile = profile
        show(page: .mapping)
    }

    @objc private func bindProfileToApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "选择要绑定此配置的应用"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier else {
            let alert = NSAlert()
            alert.messageText = "无法读取应用 Bundle ID"
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        editingProfile.bundleIdentifier = bundleID
        profileStore.upsert(editingProfile)
        reloadProfilePopup()
    }

    @objc private func renameProfile() {
        let alert = NSAlert()
        alert.messageText = "重命名配置"
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = editingProfile.name
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else { return }
        editingProfile.name = newName
        profileStore.upsert(editingProfile)
        reloadProfilePopup()
    }

    @objc private func saveMappingProfile() {
        profileStore.upsert(editingProfile)
    }

    @objc private func saveNewProfile() {
        let alert = NSAlert()
        alert.messageText = "新建配置"
        alert.informativeText = "将当前按键映射复制到新配置"
        alert.addButton(withTitle: "创建")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "配置名称"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let newProfile = MappingProfile(name: name.isEmpty ? "新配置" : name, mappings: editingProfile.mappings)
        profileStore.upsert(newProfile)
        editingProfileID = newProfile.id
        editingProfile = newProfile
        show(page: .mapping)
    }

    @objc private func deleteCurrentProfile() {
        guard !editingProfile.isDefault else { return }
        let alert = NSAlert()
        alert.messageText = "删除配置「\(editingProfile.name)」？"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        profileStore.deleteProfile(id: editingProfile.id)
        editingProfileID = nil
        editingProfile = profileStore.defaultProfile()
        show(page: .mapping)
    }

    private func styleSmallDarkButton(_ button: NSButton) {
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = .systemFont(ofSize: 12, weight: .regular)
    }

    private func flexSpacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return v
    }

    private func loadGlyph(for button: ControllerButton) -> NSImage? {
        let nameMap: [ControllerButton: String] = [
            .buttonA: "Cross",
            .buttonB: "Circle",
            .buttonX: "Square",
            .buttonY: "Triangle",
            .dpadUp: "D-Pad Up",
            .dpadDown: "D-Pad Down",
            .dpadLeft: "D-Pad Left",
            .dpadRight: "D-Pad Right",
            .leftShoulder: "L1",
            .rightShoulder: "R1",
            .leftTrigger: "L2",
            .rightTrigger: "R2",
            .leftThumbstickButton: "Left Stick Click",
            .rightThumbstickButton: "Right Stick Click",
            .buttonMenu: "Create",
            .buttonOptions: "Options",
            .buttonHome: "Home",
            .touchpadButton: "Touch Pad Press"
        ]
        guard let fileName = nameMap[button],
              let url = Bundle.module.url(forResource: fileName, withExtension: "svg"),
              let img = NSImage(contentsOf: url) else {
            if button == .buttonMicrophoneMute {
                return NSImage(systemSymbolName: "mic.slash", accessibilityDescription: nil)
            }
            return nil
        }
        img.isTemplate = true
        return img
    }

    private func configureMappingControls() {
        if gesturePopup.numberOfItems == 0 {
            for kind in PressKind.allCases {
                gesturePopup.addItem(withTitle: kind.displayName)
                gesturePopup.lastItem?.representedObject = kind.rawValue
            }
        }
        if actionPopup.numberOfItems == 0 {
            [
                ("快捷键", ActionKind.shortcut.rawValue),
                ("鼠标左键", ActionKind.mouseLeft.rawValue),
                ("鼠标右键", ActionKind.mouseRight.rawValue),
                ("鼠标中键", ActionKind.mouseMiddle.rawValue),
                ("程序切换", ActionKind.appSwitch.rawValue),
                ("打开应用", ActionKind.openApplication.rawValue),
                ("无绑定", ActionKind.none.rawValue)
            ].forEach { title, value in
                actionPopup.addItem(withTitle: title)
                actionPopup.lastItem?.representedObject = value
            }
        }
        if keyPopup.numberOfItems == 0 {
            for option in KeyCatalog.options {
                keyPopup.addItem(withTitle: option.title)
                keyPopup.lastItem?.representedObject = option.keyCode
            }
        }
        [gesturePopup, actionPopup, keyPopup].forEach {
            if $0.constraints.first(where: { $0.firstAttribute == .width }) == nil {
                $0.widthAnchor.constraint(equalToConstant: 260).isActive = true
            }
        }
        actionPopup.target = self
        actionPopup.action = #selector(actionTypeChanged)
        gesturePopup.target = self
        gesturePopup.action = #selector(loadSelection)
        keyPopup.target = self
        keyPopup.action = #selector(keyFallbackChanged)
        [commandCheck, optionCheck, controlCheck, shiftCheck].forEach {
            $0.target = self
            $0.action = #selector(keyFallbackChanged)
            $0.contentTintColor = .labelColor
        }
        recordButton.target = self
        recordButton.action = #selector(toggleRecording)
        clearButton.target = self
        clearButton.action = #selector(clearBinding)
        saveButton.target = self
        saveButton.action = #selector(saveBinding)
        chooseAppButton.target = self
        chooseAppButton.action = #selector(chooseApplication)
    }

    @objc private func selectGestureFromButton(_ sender: NSButton) {
        guard PressKind.allCases.indices.contains(sender.tag) else { return }
        let kind = PressKind.allCases[sender.tag]
        for index in 0..<gesturePopup.numberOfItems where gesturePopup.item(at: index)?.representedObject as? String == kind.rawValue {
            gesturePopup.selectItem(at: index)
            loadSelection()
            return
        }
    }

    private func buildHooksPage() -> NSView {
        if let detail = hookDetailIndex, hooks.indices.contains(detail) {
            hookTable.selectRowIndexes(IndexSet(integer: detail), byExtendingSelection: false)
            return buildHookDetailPage()
        }
        return buildHookGridPage()
    }

    private func buildHookGridPage() -> NSView {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 18
        content.edgeInsets = NSEdgeInsets(top: 34, left: 26, bottom: 34, right: 26)
        content.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Hook 配置")
        title.font = .systemFont(ofSize: 26, weight: .bold)
        title.textColor = .labelColor
        content.addArrangedSubview(title)

        var rowStack = NSStackView()
        rowStack.orientation = .horizontal
        rowStack.alignment = .top
        rowStack.spacing = 18
        content.addArrangedSubview(rowStack)

        let add = hookGridCard(title: "+", subtitle: "新建 Hook", color: NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.24, alpha: 1), index: nil)
        add.font = .systemFont(ofSize: 42, weight: .light)
        rowStack.addArrangedSubview(add)

        for (index, hook) in hooks.enumerated() {
            if rowStack.arrangedSubviews.count >= 3 {
                rowStack = NSStackView()
                rowStack.orientation = .horizontal
                rowStack.alignment = .top
                rowStack.spacing = 18
                content.addArrangedSubview(rowStack)
            }
            rowStack.addArrangedSubview(hookGridCard(
                title: hook.name,
                subtitle: "/\(hook.slug)\n\(hook.commands.count) 个指令",
                color: hookCardColor(index: index),
                index: index
            ))
        }

        scroll.documentView = content

        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        return root
    }

    private func buildHookDetailPage() -> NSView {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let form = buildHookForm()
        form.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(form)
        NSLayoutConstraint.activate([
            form.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            form.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            form.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            form.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -28)
        ])
        return root
    }

    private func hookGridCard(title: String, subtitle: String, color: NSColor, index: Int?) -> NSButton {
        let button = NSButton(title: "\(title)\n\(subtitle)", target: self, action: index == nil ? #selector(addHook) : #selector(openHookDetail(_:)))
        button.tag = index ?? -1
        button.isBordered = false
        button.alignment = .left
        button.font = .systemFont(ofSize: 16, weight: .semibold)
        button.contentTintColor = .labelColor
        button.wantsLayer = true
        button.layer?.backgroundColor = color.cgColor
        button.layer?.cornerRadius = 18
        button.widthAnchor.constraint(equalToConstant: 220).isActive = true
        button.heightAnchor.constraint(equalToConstant: 118).isActive = true
        return button
    }

    private func hookCardColor(index: Int) -> NSColor {
        let colors = [
            NSColor(calibratedRed: 0.15, green: 0.24, blue: 0.44, alpha: 1),
            NSColor(calibratedRed: 0.08, green: 0.26, blue: 0.22, alpha: 1),
            NSColor(calibratedRed: 0.10, green: 0.24, blue: 0.14, alpha: 1),
            NSColor(calibratedRed: 0.22, green: 0.16, blue: 0.36, alpha: 1)
        ]
        return colors[index % colors.count]
    }

    @objc private func openHookDetail(_ sender: NSButton) {
        guard hooks.indices.contains(sender.tag) else { return }
        hookDetailIndex = sender.tag
        show(page: .hooks)
    }

    private func buildHookForm() -> NSView {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let selectedHookName = selectedHookIndex().flatMap { hooks.indices.contains($0) ? hooks[$0].name : nil } ?? "Hook 配置"
        let title = NSTextField(labelWithString: selectedHookName)
        title.font = .systemFont(ofSize: 22, weight: .bold)
        title.textColor = .labelColor

        configureHookControls()
        [hookNameField, hookSlugField, hookURLField, hookBrightnessField, hookIntervalField, hookDurationField, hookStrengthField, hookPlayerMaskField].forEach {
            if $0.constraints.first(where: { $0.firstAttribute == .width }) == nil {
                $0.widthAnchor.constraint(equalToConstant: 320).isActive = true
            }
        }
        hookURLField.isEditable = false
        hookURLField.textColor = .labelColor
        hookStatusLabel.textColor = .secondaryLabelColor
        hookStatusLabel.maximumNumberOfLines = 2

        hookSlugField.target = self
        hookSlugField.action = #selector(hookSlugChanged)

        let add = NSButton(title: "新建", target: self, action: #selector(addHook))
        let delete = NSButton(title: "删除", target: self, action: #selector(deleteHook))
        let save = NSButton(title: "保存", target: self, action: #selector(saveHook))
        let copy = NSButton(title: "复制 URL", target: self, action: #selector(copyHookURL))
        let test = NSButton(title: "立即测试", target: self, action: #selector(testHook))
        let deleteCommand = NSButton(title: "删除指令", target: self, action: #selector(deleteCommand))
        let back = NSButton(title: "返回", target: self, action: #selector(backToHookGrid))

        let base = NSStackView()
        base.orientation = .vertical
        base.alignment = .leading
        base.spacing = 12
        base.translatesAutoresizingMaskIntoConstraints = false
        base.addArrangedSubview(row([back, title]))
        base.addArrangedSubview(labeled("名称", hookNameField))
        base.addArrangedSubview(labeled("Slug", hookSlugField))
        base.addArrangedSubview(hookEnabledCheck)
        base.addArrangedSubview(labeled("URL", hookURLField))
        base.addArrangedSubview(row([copy, test]))
        base.addArrangedSubview(row([add, delete, save]))

        let commandScroll = NSScrollView()
        commandScroll.translatesAutoresizingMaskIntoConstraints = false
        commandScroll.hasVerticalScroller = true
        commandTable.delegate = self
        commandTable.dataSource = self
        commandTable.headerView = nil
        commandTable.rowHeight = 56
        if commandTable.tableColumns.isEmpty {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
            column.width = 230
            commandTable.addTableColumn(column)
        }
        commandScroll.documentView = commandTable

        let commandList = NSStackView()
        commandList.orientation = .vertical
        commandList.alignment = .leading
        commandList.spacing = 10
        commandList.translatesAutoresizingMaskIntoConstraints = false
        let commandTitle = NSTextField(labelWithString: "指令")
        commandTitle.font = .systemFont(ofSize: 16, weight: .bold)
        commandTitle.textColor = .labelColor
        commandList.addArrangedSubview(commandTitle)
        commandList.addArrangedSubview(addCommandPopup)
        commandList.addArrangedSubview(commandScroll)
        commandList.addArrangedSubview(deleteCommand)
        commandScroll.widthAnchor.constraint(equalToConstant: 240).isActive = true
        commandScroll.heightAnchor.constraint(equalToConstant: 300).isActive = true

        let params = NSStackView()
        params.orientation = .vertical
        params.alignment = .leading
        params.spacing = 12
        params.translatesAutoresizingMaskIntoConstraints = false
        let paramsTitle = NSTextField(labelWithString: "指令参数")
        paramsTitle.font = .systemFont(ofSize: 16, weight: .bold)
        paramsTitle.textColor = .labelColor
        params.addArrangedSubview(paramsTitle)
        params.addArrangedSubview(labeled("类型", commandKindPopup))
        params.addArrangedSubview(labeled("颜色 A", hookColorAWell))
        params.addArrangedSubview(labeled("颜色 B", hookColorBWell))
        params.addArrangedSubview(labeled("亮度 0-1", hookBrightnessField))
        params.addArrangedSubview(labeled("间隔 ms", hookIntervalField))
        params.addArrangedSubview(labeled("节拍时长 ms", hookDurationField))
        params.addArrangedSubview(labeled("震动强度 0-1", hookStrengthField))
        params.addArrangedSubview(labeled("Player mask 0-31", hookPlayerMaskField))
        params.addArrangedSubview(labeled("Player 亮度", hookPlayerBrightnessPopup))
        params.addArrangedSubview(labeled("停止 channel", hookStopChannelPopup))
        params.addArrangedSubview(hookResetCheck)
        params.addArrangedSubview(hookStatusLabel)

        root.addSubview(base)
        root.addSubview(commandList)
        root.addSubview(params)
        NSLayoutConstraint.activate([
            base.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            base.topAnchor.constraint(equalTo: root.topAnchor),
            base.widthAnchor.constraint(equalToConstant: 340),
            commandList.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            commandList.topAnchor.constraint(equalTo: base.bottomAnchor, constant: 24),
            commandList.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor),
            params.leadingAnchor.constraint(equalTo: commandList.trailingAnchor, constant: 28),
            params.topAnchor.constraint(equalTo: commandList.topAnchor),
            params.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor),
            params.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor)
        ])
        return root
    }

    @objc private func backToHookGrid() {
        commitSelectedCommand()
        hookDetailIndex = nil
        show(page: .hooks)
    }

    private func configureHookControls() {
        if addCommandPopup.numberOfItems == 0 {
            addCommandPopup.addItem(withTitle: "添加指令...")
            for kind in HookCommandKind.allCases {
                addCommandPopup.addItem(withTitle: kind.displayName)
                addCommandPopup.lastItem?.representedObject = kind.rawValue
            }
            addCommandPopup.target = self
            addCommandPopup.action = #selector(addCommand)
        }
        if commandKindPopup.numberOfItems == 0 {
            for kind in HookCommandKind.allCases {
                commandKindPopup.addItem(withTitle: kind.displayName)
                commandKindPopup.lastItem?.representedObject = kind.rawValue
            }
            commandKindPopup.target = self
            commandKindPopup.action = #selector(commandKindChanged)
        }
        if hookStopChannelPopup.numberOfItems == 0 {
            for channel in HookStopChannel.allCases {
                hookStopChannelPopup.addItem(withTitle: channel.displayName)
                hookStopChannelPopup.lastItem?.representedObject = channel.rawValue
            }
        }
        hookPlayerBrightnessPopup.removeAllItems()
        [("默认", -1), ("亮", 0), ("中", 1), ("暗", 2)].forEach { title, value in
            hookPlayerBrightnessPopup.addItem(withTitle: title)
            hookPlayerBrightnessPopup.lastItem?.representedObject = value
        }
        [addCommandPopup, commandKindPopup, hookStopChannelPopup, hookPlayerBrightnessPopup].forEach {
            if $0.constraints.first(where: { $0.firstAttribute == .width }) == nil {
                $0.widthAnchor.constraint(equalToConstant: 220).isActive = true
            }
        }
    }

    private func buildSettingsPage() -> NSView {
        loadPreferences()
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 26
        root.edgeInsets = NSEdgeInsets(top: 28, left: 48, bottom: 40, right: 48)
        root.translatesAutoresizingMaskIntoConstraints = false

        root.addArrangedSubview(settingsSection(title: "触控板配置", rows: [
            settingsRow(title: "触控鼠标", control: configToggle(title: "", tag: 11, isOn: config.touchpad.enabled)),
            settingsRow(title: "单指轻触点击", control: configToggle(title: "", tag: 10, isOn: profileStore.defaultProfile().mappings[ButtonGesture(button: .touchpadOneFingerTap, kind: .singleClick)] != nil)),
            settingsRow(title: "双指轻触右键", control: configToggle(title: "", tag: 16, isOn: profileStore.defaultProfile().mappings[ButtonGesture(button: .touchpadTwoFingerTap, kind: .singleClick)] != nil)),
            settingsRow(title: "触控按下模拟鼠标按下", control: configToggle(title: "", tag: 12, isOn: profileStore.defaultProfile().mappings[ButtonGesture(button: .touchpadButton, kind: .press)] != nil)),
            settingsRow(title: "双指滑动", control: configToggle(title: "", tag: 13, isOn: config.touchpad.scrollSensitivity > 0)),
            settingsRow(title: "鼠标灵敏度", control: configNumberField(value: config.touchpad.sensitivity, tag: 30)),
            settingsRow(title: "滚动灵敏度", control: configNumberField(value: config.touchpad.scrollSensitivity, tag: 31)),
            settingsRow(title: "死区", control: configNumberField(value: config.touchpad.deadZone, tag: 32)),
            settingsRow(title: "反转 X", control: configToggle(title: "", tag: 17, isOn: config.touchpad.invertX)),
            settingsRow(title: "反转 Y", control: configToggle(title: "", tag: 18, isOn: config.touchpad.invertY)),
            settingsRow(title: "加速度", control: configToggle(title: "", tag: 19, isOn: config.touchpad.accelerationEnabled))
        ]))

        root.addArrangedSubview(settingsSection(title: "摇杆配置", rows: [
            settingsRow(title: "左摇杆鼠标控制", control: configToggle(title: "", tag: 20, isOn: config.touchpad.leftStickMouseEnabled)),
            settingsRow(title: "右摇杆鼠标控制", control: configToggle(title: "", tag: 21, isOn: config.touchpad.rightStickMouseEnabled)),
            settingsRow(title: "摇杆移动灵敏度", control: configNumberField(value: config.touchpad.sensitivity, tag: 30)),
            settingsRow(title: "摇杆死区", control: configNumberField(value: config.touchpad.deadZone, tag: 32))
        ]))

        scroll.documentView = root
        root.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        return scroll
    }

    private func settingsSection(title: String, rows: [NSView]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 28, weight: .bold)
        heading.textColor = .labelColor
        stack.addArrangedSubview(heading)
        rows.forEach { stack.addArrangedSubview($0) }
        stack.addArrangedSubview(separator(width: 700))
        return stack
    }

    private func settingsRow(title: String, control: NSView) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        let titleLabel = label(title, width: 360)
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        row.addArrangedSubview(titleLabel)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(control)
        row.widthAnchor.constraint(equalToConstant: 700).isActive = true
        return row
    }

    private func configToggle(title: String, tag: Int, isOn: Bool) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: #selector(settingsToggleChanged(_:)))
        button.tag = tag
        button.state = isOn ? .on : .off
        button.contentTintColor = .labelColor
        return button
    }

    private func configNumberField(value: Double, tag: Int) -> NSTextField {
        let field = NSTextField(string: String(format: tag == 32 ? "%.3f" : "%.1f", value))
        field.tag = tag
        field.target = self
        field.action = #selector(settingsNumberChanged(_:))
        field.alignment = .right
        field.widthAnchor.constraint(equalToConstant: 96).isActive = true
        return field
    }

    @objc private func settingsToggleChanged(_ sender: NSButton) {
        switch sender.tag {
        case 10:
            let gesture = ButtonGesture(button: .touchpadOneFingerTap, kind: .singleClick)
            var def = profileStore.defaultProfile()
            def.mappings[gesture] = sender.state == .on ? [.mouseClick(.left)] : nil
            profileStore.upsert(def)
            if editingProfile.id == def.id { editingProfile = def }
            return
        case 11:
            config.touchpad.enabled = sender.state == .on
        case 12:
            let gesture = ButtonGesture(button: .touchpadButton, kind: .press)
            var def = profileStore.defaultProfile()
            def.mappings[gesture] = sender.state == .on ? [.mouseClick(.left)] : nil
            profileStore.upsert(def)
            if editingProfile.id == def.id { editingProfile = def }
            return
        case 13:
            config.touchpad.scrollSensitivity = sender.state == .on ? 14 : 0
        case 16:
            let gesture = ButtonGesture(button: .touchpadTwoFingerTap, kind: .singleClick)
            var def = profileStore.defaultProfile()
            def.mappings[gesture] = sender.state == .on ? [.mouseClick(.right)] : nil
            profileStore.upsert(def)
            if editingProfile.id == def.id { editingProfile = def }
            return
        case 17:
            config.touchpad.invertX = sender.state == .on
        case 18:
            config.touchpad.invertY = sender.state == .on
        case 19:
            config.touchpad.accelerationEnabled = sender.state == .on
        case 20:
            config.touchpad.leftStickMouseEnabled = sender.state == .on
        case 21:
            config.touchpad.rightStickMouseEnabled = sender.state == .on
        default:
            break
        }
        configStore.save(config)
    }

    @objc private func settingsNumberChanged(_ sender: NSTextField) {
        let value = sender.doubleValue
        switch sender.tag {
        case 30:
            config.touchpad.sensitivity = min(5000, max(50, value))
        case 31:
            config.touchpad.scrollSensitivity = min(100, max(0, value))
        case 32:
            config.touchpad.deadZone = min(0.5, max(0, value))
        default:
            return
        }
        configStore.save(config)
        sender.stringValue = String(format: sender.tag == 32 ? "%.3f" : "%.1f", sender.tag == 30 ? config.touchpad.sensitivity : sender.tag == 31 ? config.touchpad.scrollSensitivity : config.touchpad.deadZone)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === commandTable {
            guard let index = selectedHookIndex() else { return 0 }
            return hooks[index].commands.count
        }
        return hooks.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === commandTable {
            guard let hookIndex = selectedHookIndex(), hooks[hookIndex].commands.indices.contains(row) else { return nil }
            return commandCell(for: hooks[hookIndex].commands[row], row: row)
        }
        guard hooks.indices.contains(row) else { return nil }
        return hookCell(for: hooks[row])
    }

    private func hookCell(for hook: HookDefinition) -> NSView {
        let id = NSUserInterfaceItemIdentifier("HookCell")
        let cell = hookTable.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = id
        cell.subviews.forEach { $0.removeFromSuperview() }
        let label = NSTextField(labelWithString: "\(hook.enabled ? "" : "停用 ") \(hook.name)\n\(hook.slug)")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private func commandCell(for command: HookCommand, row: Int) -> NSView {
        let id = NSUserInterfaceItemIdentifier("CommandCell")
        let cell = commandTable.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = id
        cell.subviews.forEach { $0.removeFromSuperview() }
        let label = NSTextField(labelWithString: "\(row + 1). \(command.kind.displayName)\n\(command.summary)")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView = notification.object as? NSTableView else { return }
        if tableView === hookTable {
            commitSelectedCommand()
            loadSelectedHook()
        } else if tableView === commandTable {
            commitSelectedCommand()
            loadSelectedCommand()
        }
    }

    private func selectedHookIndex() -> Int? {
        if let hookDetailIndex, hooks.indices.contains(hookDetailIndex) {
            return hookDetailIndex
        }
        let row = hookTable.selectedRow
        return hooks.indices.contains(row) ? row : nil
    }

    private func selectedCommandIndex() -> Int? {
        guard let hookIndex = selectedHookIndex() else { return nil }
        let row = commandTable.selectedRow
        return hooks[hookIndex].commands.indices.contains(row) ? row : nil
    }

    private func loadSelectedHook() {
        guard let index = selectedHookIndex() else {
            editingHookID = nil
            editingCommandID = nil
            clearCommandForm()
            hookStatusLabel.stringValue = "选择一个 hook 或新建一个。"
            return
        }
        let hook = hooks[index]
        editingHookID = hook.id
        editingCommandID = nil
        hookNameField.stringValue = hook.name
        hookSlugField.stringValue = hook.slug
        hookEnabledCheck.state = hook.enabled ? .on : .off
        hookURLField.stringValue = HookHTTPServer.url(for: hook.slug)
        commandTable.reloadData()
        if hook.commands.isEmpty {
            clearCommandForm()
        } else if !hook.commands.indices.contains(commandTable.selectedRow) {
            commandTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } else {
            loadSelectedCommand()
        }
        hookStatusLabel.stringValue = ""
    }

    private func loadSelectedCommand() {
        guard
            let hookIndex = selectedHookIndex(),
            let commandIndex = selectedCommandIndex()
        else {
            clearCommandForm()
            return
        }
        let command = hooks[hookIndex].commands[commandIndex]
        editingHookID = hooks[hookIndex].id
        editingCommandID = command.id
        apply(command: command)
    }

    private func clearCommandForm() {
        editingCommandID = nil
        selectCommandKind(.solidLightbar)
        selectStopChannel(.all)
        hookColorAWell.color = NSColor(HookColor.reflashBlue)
        hookColorBWell.color = NSColor(HookColor.blue)
        hookBrightnessField.stringValue = "1.00"
        hookIntervalField.stringValue = "500"
        hookDurationField.stringValue = "160"
        hookStrengthField.stringValue = "0.80"
        hookPlayerMaskField.stringValue = "4"
        hookPlayerBrightnessPopup.selectItem(withTitle: "默认")
        hookResetCheck.state = .on
        updateCommandControlState(for: .solidLightbar)
    }

    private func apply(command: HookCommand) {
        selectCommandKind(command.kind)
        selectStopChannel(command.stopChannel)
        hookColorAWell.color = NSColor(command.colorA)
        hookColorBWell.color = NSColor(command.colorB)
        hookBrightnessField.stringValue = String(format: "%.2f", command.brightness)
        hookIntervalField.stringValue = "\(command.intervalMs)"
        hookDurationField.stringValue = "\(command.durationMs)"
        hookStrengthField.stringValue = String(format: "%.2f", command.strength)
        hookPlayerMaskField.stringValue = "\(command.playerMask)"
        hookPlayerBrightnessPopup.selectItem(withTitle: command.playerBrightness.map { ["亮", "中", "暗"][Int($0)] } ?? "默认")
        hookResetCheck.state = command.resetOnStop ? .on : .off
        updateCommandControlState(for: command.kind)
    }

    @objc private func hookSlugChanged() {
        hookURLField.stringValue = HookHTTPServer.url(for: hookSlugField.stringValue)
    }

    @objc private func commandKindChanged() {
        guard var command = selectedCommandFromForm() else { return }
        if let kind = selectedCommandKind() {
            command.kind = kind
            apply(command: command)
            hookStatusLabel.stringValue = kind.displayName
        }
    }

    @objc private func addCommand() {
        guard
            let hookIndex = selectedHookIndex(),
            let raw = addCommandPopup.selectedItem?.representedObject as? String,
            let kind = HookCommandKind(rawValue: raw)
        else {
            addCommandPopup.selectItem(at: 0)
            return
        }
        commitSelectedCommand()
        hooks[hookIndex].commands.append(HookCommand(kind: kind))
        commandTable.reloadData()
        commandTable.selectRowIndexes(IndexSet(integer: hooks[hookIndex].commands.count - 1), byExtendingSelection: false)
        addCommandPopup.selectItem(at: 0)
        hookStatusLabel.stringValue = "已添加指令，点击保存写入 hooks.json"
    }

    @objc private func deleteCommand() {
        guard let hookIndex = selectedHookIndex(), let commandIndex = selectedCommandIndex() else { return }
        hooks[hookIndex].commands.remove(at: commandIndex)
        editingCommandID = nil
        commandTable.reloadData()
        if hooks[hookIndex].commands.indices.contains(commandIndex) {
            commandTable.selectRowIndexes(IndexSet(integer: commandIndex), byExtendingSelection: false)
        } else if !hooks[hookIndex].commands.isEmpty {
            commandTable.selectRowIndexes(IndexSet(integer: hooks[hookIndex].commands.count - 1), byExtendingSelection: false)
        } else {
            clearCommandForm()
        }
        hookStatusLabel.stringValue = "已删除指令，点击保存写入 hooks.json"
    }

    @objc private func addHook() {
        var hook = HookDefinition(name: "new-hook", slug: "new-hook", commands: [HookCommand(kind: .solidLightbar)])
        hook.slug = uniqueSlug(hook.slug)
        hooks.append(hook)
        hookDetailIndex = hooks.count - 1
        persistHooks(selecting: hooks.count - 1)
        show(page: .hooks)
    }

    @objc private func deleteHook() {
        guard let index = selectedHookIndex() else { return }
        hooks.remove(at: index)
        hookDetailIndex = nil
        persistHooks(selecting: min(index, hooks.count - 1))
        show(page: .hooks)
    }

    @objc private func saveHook() {
        guard let index = selectedHookIndex() else { return }
        commitSelectedCommand()
        hooks[index] = readHookFromForm(existing: hooks[index])
        persistHooks(selecting: index)
        hookStatusLabel.stringValue = "已保存"
    }

    @objc private func copyHookURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hookURLField.stringValue, forType: .string)
        hookStatusLabel.stringValue = "URL 已复制"
    }

    @objc private func testHook() {
        commitSelectedCommand()
        let hook = readHookFromForm(existing: selectedHookIndex().map { hooks[$0] } ?? HookDefinition(name: "test", slug: "test", commands: [HookCommand(kind: .solidLightbar)]))
        let result = hookService.execute(hook, source: "manual-test")
        hookStatusLabel.stringValue = result.ok ? "已触发：\(result.message)" : "失败：\(result.message)"
    }

    private func readHookFromForm(existing: HookDefinition) -> HookDefinition {
        return HookDefinition(
            id: existing.id,
            name: hookNameField.stringValue,
            slug: uniqueSlug(hookSlugField.stringValue, excluding: existing.id),
            enabled: hookEnabledCheck.state == .on,
            commands: existing.commands
        )
    }

    private func commitSelectedCommand() {
        guard
            let hookID = editingHookID,
            let commandID = editingCommandID,
            let hookIndex = hooks.firstIndex(where: { $0.id == hookID }),
            let commandIndex = hooks[hookIndex].commands.firstIndex(where: { $0.id == commandID })
        else { return }
        hooks[hookIndex].commands[commandIndex] = commandFromForm(existing: hooks[hookIndex].commands[commandIndex])
        commandTable.reloadData()
    }

    private func selectedCommandFromForm() -> HookCommand? {
        guard
            let hookID = editingHookID,
            let commandID = editingCommandID,
            let hookIndex = hooks.firstIndex(where: { $0.id == hookID }),
            let commandIndex = hooks[hookIndex].commands.firstIndex(where: { $0.id == commandID })
        else { return nil }
        return commandFromForm(existing: hooks[hookIndex].commands[commandIndex])
    }

    private func commandFromForm(existing: HookCommand) -> HookCommand {
        let playerBrightnessValue = hookPlayerBrightnessPopup.selectedItem?.representedObject as? Int ?? -1
        return HookCommand(
            id: existing.id,
            kind: selectedCommandKind() ?? existing.kind,
            colorA: HookColor(hookColorAWell.color),
            colorB: HookColor(hookColorBWell.color),
            brightness: Float(hookBrightnessField.stringValue) ?? existing.brightness,
            intervalMs: hookIntervalField.integerValue,
            durationMs: hookDurationField.integerValue,
            strength: Float(hookStrengthField.stringValue) ?? existing.strength,
            playerMask: UInt8(clamping: hookPlayerMaskField.integerValue),
            playerBrightness: playerBrightnessValue < 0 ? nil : UInt8(clamping: playerBrightnessValue),
            stopChannel: selectedStopChannel() ?? existing.stopChannel,
            resetOnStop: hookResetCheck.state == .on
        )
    }

    private func selectedCommandKind() -> HookCommandKind? {
        guard
            let raw = commandKindPopup.selectedItem?.representedObject as? String,
            let kind = HookCommandKind(rawValue: raw)
        else { return nil }
        return kind
    }

    private func selectCommandKind(_ kind: HookCommandKind) {
        for index in 0..<commandKindPopup.numberOfItems where commandKindPopup.item(at: index)?.representedObject as? String == kind.rawValue {
            commandKindPopup.selectItem(at: index)
            return
        }
    }

    private func selectedStopChannel() -> HookStopChannel? {
        guard
            let raw = hookStopChannelPopup.selectedItem?.representedObject as? String,
            let channel = HookStopChannel(rawValue: raw)
        else { return nil }
        return channel
    }

    private func selectStopChannel(_ channel: HookStopChannel) {
        for index in 0..<hookStopChannelPopup.numberOfItems where hookStopChannelPopup.item(at: index)?.representedObject as? String == channel.rawValue {
            hookStopChannelPopup.selectItem(at: index)
            return
        }
    }

    private func updateCommandControlState(for kind: HookCommandKind) {
        let usesColorA = [.solidLightbar, .breathingLightbar, .alternatingLightbar].contains(kind)
        let usesColorB = kind == .alternatingLightbar
        let usesBrightness = [.solidLightbar, .breathingLightbar, .alternatingLightbar, .playerLEDs].contains(kind)
        let usesInterval = [.heartbeatRumble, .breathingLightbar, .alternatingLightbar].contains(kind)
        let usesRumble = kind == .heartbeatRumble
        let usesPlayer = kind == .playerLEDs
        let usesStop = kind == .stopEffects

        hookColorAWell.superview?.isHidden = !usesColorA
        hookColorBWell.superview?.isHidden = !usesColorB
        hookBrightnessField.superview?.isHidden = !usesBrightness
        hookIntervalField.superview?.isHidden = !usesInterval
        hookDurationField.superview?.isHidden = !usesRumble
        hookStrengthField.superview?.isHidden = !usesRumble
        hookPlayerMaskField.superview?.isHidden = !usesPlayer
        hookPlayerBrightnessPopup.superview?.isHidden = !usesPlayer
        hookStopChannelPopup.superview?.isHidden = !usesStop
        hookResetCheck.isHidden = !usesStop
    }

    private func persistHooks(selecting index: Int) {
        hookStore.save(hooks)
        hooks = hookStore.hooks
        hookTable.reloadData()
        commandTable.reloadData()
        if hooks.indices.contains(index) {
            hookTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            loadSelectedHook()
        }
    }

    private func uniqueSlug(_ raw: String, excluding id: UUID? = nil) -> String {
        let base = HookDefinition.sanitizeSlug(raw)
        let existing = Set(hooks.filter { $0.id != id }.map(\.slug))
        guard existing.contains(base) else { return base }
        var counter = 2
        while existing.contains("\(base)-\(counter)") {
            counter += 1
        }
        return "\(base)-\(counter)"
    }

    @objc private func loadSelection() {
        selectedTitle.stringValue = selectedButton.displayName
        let gesture = currentGesture()
        let actions = editingProfile.mappings[gesture] ?? []
        advancedLabel.isHidden = actions.count <= 1 && actions.first?.supportedActionKind != nil

        if actions.count > 1 {
            advancedLabel.stringValue = "高级配置：此触发方式包含 \(actions.count) 个动作。保存会替换为当前 UI 选择。"
        } else if let action = actions.first, action.supportedActionKind == nil {
            advancedLabel.stringValue = "高级配置：此动作暂未在正式 UI 暴露。保存会替换为当前 UI 选择。"
        } else {
            advancedLabel.stringValue = ""
        }

        let first = actions.first
        let kind = first?.supportedActionKind ?? .none
        selectActionKind(kind)
        selectedApplicationPath = nil
        capturedStroke = nil

        switch first {
        case .keyStroke(let stroke):
            apply(stroke: stroke)
        case .openApplication(let path):
            selectedApplicationPath = path
            appPathLabel.stringValue = (path as NSString).lastPathComponent
        default:
            appPathLabel.stringValue = "未选择应用"
        }
        summaryLabel.stringValue = summaryText(for: actions)
        updateActionControls()
    }

    private func select(_ button: ControllerButton) {
        selectedButton = button
        previewView.selectedButton = button
        loadSelection()
    }

    @objc private func actionTypeChanged() {
        let kind = currentActionKind()
        if kind == .appSwitch {
            let stroke = appSwitchStroke()
            capturedStroke = stroke
            apply(stroke: stroke)
        }
        updateActionControls()
    }

    @objc private func keyFallbackChanged() {
        guard currentActionKind() == .shortcut else { return }
        capturedStroke = selectedFallbackStroke()
        summaryLabel.stringValue = KeyCatalog.describe(capturedStroke!)
    }

    @objc private func toggleRecording() {
        if keyMonitor != nil {
            stopRecording()
            return
        }
        recordButton.title = "按下快捷键..."
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.capture(event)
            return nil
        }
    }

    @objc private func clearBinding() {
        editingProfile.mappings[currentGesture()] = nil
        profileStore.upsert(editingProfile)
        reloadSlotSummaries()
        loadSelection()
    }

    @objc private func saveBinding() {
        let gesture = currentGesture()
        switch currentActionKind() {
        case .none:
            editingProfile.mappings[gesture] = nil
        case .shortcut:
            editingProfile.mappings[gesture] = [.keyStroke(capturedStroke ?? selectedFallbackStroke())]
        case .mouseLeft:
            editingProfile.mappings[gesture] = [.mouseClick(.left)]
        case .mouseRight:
            editingProfile.mappings[gesture] = [.mouseClick(.right)]
        case .mouseMiddle:
            editingProfile.mappings[gesture] = [.mouseClick(.middle)]
        case .appSwitch:
            editingProfile.mappings[gesture] = [.keyStroke(appSwitchStroke())]
        case .openApplication:
            guard let selectedApplicationPath else {
                NSSound.beep()
                return
            }
            editingProfile.mappings[gesture] = [.openApplication(selectedApplicationPath)]
        }
        profileStore.upsert(editingProfile)
        reloadSlotSummaries()
        loadSelection()
    }

    @objc private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectedApplicationPath = url.path
        appPathLabel.stringValue = url.lastPathComponent
        selectActionKind(.openApplication)
        updateActionControls()
    }

    @objc private func preferencesChanged() {
        preferences.launchAtLogin = launchCheck.state == .on
        preferences.showDockIcon = dockCheck.state == .on
        preferences.showStatusItem = statusCheck.state == .on
        onPreferencesChanged()
    }

    private func loadPreferences() {
        launchCheck.state = preferences.launchAtLogin ? .on : .off
        dockCheck.state = preferences.showDockIcon ? .on : .off
        statusCheck.state = preferences.showStatusItem ? .on : .off
    }

    private func capture(_ event: NSEvent) {
        if event.keyCode == 53 {
            stopRecording()
            return
        }
        let stroke = KeyStroke(keyCode: UInt16(event.keyCode), modifiers: modifiers(from: event.modifierFlags))
        capturedStroke = stroke
        apply(stroke: stroke)
        selectActionKind(.shortcut)
        summaryLabel.stringValue = KeyCatalog.describe(stroke)
        stopRecording()
    }

    private func stopRecording() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        recordButton.title = "录制快捷键"
    }

    private func currentGesture() -> ButtonGesture {
        ButtonGesture(button: selectedButton, kind: currentPressKind())
    }

    private func currentPressKind() -> PressKind {
        guard
            let raw = gesturePopup.selectedItem?.representedObject as? String,
            let kind = PressKind(rawValue: raw)
        else { return .press }
        return kind
    }

    private func currentActionKind() -> ActionKind {
        guard
            let raw = actionPopup.selectedItem?.representedObject as? String,
            let kind = ActionKind(rawValue: raw)
        else { return .none }
        return kind
    }

    private func selectActionKind(_ kind: ActionKind) {
        for index in 0..<actionPopup.numberOfItems where actionPopup.item(at: index)?.representedObject as? String == kind.rawValue {
            actionPopup.selectItem(at: index)
            return
        }
    }

    private func selectedFallbackStroke() -> KeyStroke {
        let code = keyPopup.selectedItem?.representedObject as? UInt16 ?? KeyCatalog.tabCode
        return KeyStroke(keyCode: code, modifiers: selectedModifiers())
    }

    private func selectedModifiers() -> [KeyModifier] {
        var modifiers: [KeyModifier] = []
        if commandCheck.state == .on { modifiers.append(.command) }
        if optionCheck.state == .on { modifiers.append(.option) }
        if controlCheck.state == .on { modifiers.append(.control) }
        if shiftCheck.state == .on { modifiers.append(.shift) }
        return modifiers
    }

    private func modifiers(from flags: NSEvent.ModifierFlags) -> [KeyModifier] {
        var modifiers: [KeyModifier] = []
        if flags.contains(.command) { modifiers.append(.command) }
        if flags.contains(.option) { modifiers.append(.option) }
        if flags.contains(.control) { modifiers.append(.control) }
        if flags.contains(.shift) { modifiers.append(.shift) }
        return modifiers
    }

    private func apply(stroke: KeyStroke) {
        capturedStroke = stroke
        commandCheck.state = stroke.modifiers.contains(.command) ? .on : .off
        optionCheck.state = stroke.modifiers.contains(.option) ? .on : .off
        controlCheck.state = stroke.modifiers.contains(.control) ? .on : .off
        shiftCheck.state = stroke.modifiers.contains(.shift) ? .on : .off
        for index in 0..<keyPopup.numberOfItems where keyPopup.item(at: index)?.representedObject as? UInt16 == stroke.keyCode {
            keyPopup.selectItem(at: index)
            break
        }
    }

    private func appSwitchStroke() -> KeyStroke {
        if selectedButton == .leftShoulder {
            return KeyStroke(keyCode: KeyCatalog.tabCode, modifiers: [.command, .shift])
        }
        return KeyStroke(keyCode: KeyCatalog.tabCode, modifiers: [.command])
    }

    private func updateActionControls() {
        let kind = currentActionKind()
        let isShortcut = kind == .shortcut || kind == .appSwitch
        keyPopup.isEnabled = kind == .shortcut
        [commandCheck, optionCheck, controlCheck, shiftCheck, recordButton].forEach { $0.isEnabled = isShortcut }
        chooseAppButton.isEnabled = kind == .openApplication
        appPathLabel.textColor = kind == .openApplication ? .labelColor : .disabledControlTextColor
        if kind == .none {
            summaryLabel.stringValue = "未绑定"
        } else if let stroke = capturedStroke, isShortcut {
            summaryLabel.stringValue = KeyCatalog.describe(stroke)
        }
    }

    private func summaryText(for actions: [Action]) -> String {
        guard let action = actions.first else { return "未绑定" }
        if actions.count > 1 { return "多动作绑定" }
        switch action {
        case .keyStroke(let stroke):
            return KeyCatalog.describe(stroke)
        case .mouseClick(let button):
            switch button {
            case .left: return "鼠标左键"
            case .right: return "鼠标右键"
            case .middle: return "鼠标中键"
            }
        case .openApplication(let path):
            return "打开 " + (path as NSString).lastPathComponent
        default:
            return "高级动作"
        }
    }

    private func labeled(_ title: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .labelColor
        let stack = NSStackView(views: [label, control])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        return stack
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    private func label(_ title: String, width: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .labelColor
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
        return label
    }

    private func spacer(height: CGFloat) -> NSView {
        let view = NSView()
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }

    private func separator(width: CGFloat) -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: width).isActive = true
        return box
    }
}

private enum ActionKind: String {
    case shortcut
    case mouseLeft
    case mouseRight
    case mouseMiddle
    case appSwitch
    case openApplication
    case none
}

private extension Action {
    var supportedActionKind: ActionKind? {
        switch self {
        case .keyStroke(let stroke) where stroke.keyCode == KeyCatalog.tabCode && stroke.modifiers == [.command]:
            return .appSwitch
        case .keyStroke(let stroke) where stroke.keyCode == KeyCatalog.tabCode && stroke.modifiers == [.command, .shift]:
            return .appSwitch
        case .keyStroke:
            return .shortcut
        case .mouseClick(.left):
            return .mouseLeft
        case .mouseClick(.right):
            return .mouseRight
        case .mouseClick(.middle):
            return .mouseMiddle
        case .openApplication:
            return .openApplication
        default:
            return nil
        }
    }
}

private extension ControllerButton {
    var displayName: String {
        switch self {
        case .buttonA: return "Cross / ×"
        case .buttonB: return "Circle / ○"
        case .buttonX: return "Square / □"
        case .buttonY: return "Triangle / △"
        case .dpadUp: return "上方向键"
        case .dpadDown: return "下方向键"
        case .dpadLeft: return "左方向键"
        case .dpadRight: return "右方向键"
        case .leftShoulder: return "L1"
        case .rightShoulder: return "R1"
        case .leftTrigger: return "L2"
        case .rightTrigger: return "R2"
        case .leftThumbstickButton: return "L3"
        case .rightThumbstickButton: return "R3"
        case .buttonMenu: return "Create / Menu"
        case .buttonOptions: return "Options"
        case .buttonHome: return "PS"
        case .buttonMicrophoneMute: return "麦克风静音键"
        case .touchpadButton: return "触摸板按下"
        case .touchpadOneFingerTap: return "触摸板单指轻点"
        case .touchpadTwoFingerTap: return "触摸板双指轻点"
        }
    }
}

private extension PressKind {
    var displayName: String {
        switch self {
        case .press: return "按下"
        case .release: return "松开"
        case .singleClick: return "单击"
        case .doubleClick: return "双击"
        case .longPress: return "长按"
        }
    }
}

private extension HookCommand {
    var summary: String {
        switch kind {
        case .heartbeatRumble:
            return "\(intervalMs)ms / \(durationMs)ms / \(String(format: "%.2f", strength))"
        case .playerLEDs:
            return "mask \(playerMask)" + (playerBrightness.map { " / brightness \($0)" } ?? "")
        case .solidLightbar:
            return colorSummary(colorA)
        case .breathingLightbar:
            return "\(colorSummary(colorA)) / \(intervalMs)ms"
        case .alternatingLightbar:
            return "\(colorSummary(colorA)) ↔ \(colorSummary(colorB)) / \(intervalMs)ms"
        case .stopEffects:
            return stopChannel.displayName
        }
    }

    private func colorSummary(_ color: HookColor) -> String {
        "RGB(\(color.r), \(color.g), \(color.b))"
    }
}

private extension NSColor {
    convenience init(_ color: HookColor) {
        self.init(
            calibratedRed: CGFloat(color.r) / 255,
            green: CGFloat(color.g) / 255,
            blue: CGFloat(color.b) / 255,
            alpha: 1
        )
    }
}

private extension HookColor {
    init(_ color: NSColor) {
        let converted = color.usingColorSpace(.deviceRGB) ?? color
        self.init(
            r: UInt8(clamping: Int(converted.redComponent * 255)),
            g: UInt8(clamping: Int(converted.greenComponent * 255)),
            b: UInt8(clamping: Int(converted.blueComponent * 255))
        )
    }
}

// MARK: - ButtonSlotView

final class ButtonSlotView: NSView {
    let controllerButton: ControllerButton
    var onChevronClicked: (() -> Void)?
    private let summaryLabel = NSTextField(labelWithString: "—")

    init(button: ControllerButton, glyphImage: NSImage?) {
        self.controllerButton = button
        super.init(frame: .zero)
        setup(glyphImage: glyphImage)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup(glyphImage: NSImage?) {
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.21, alpha: 1).cgColor
        layer?.cornerRadius = 7

        let glyphView = NSImageView()
        if let img = glyphImage {
            glyphView.image = img
            glyphView.image?.isTemplate = true
            glyphView.contentTintColor = NSColor(white: 0.68, alpha: 1)
        } else {
            let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .light)
            glyphView.image = NSImage(systemSymbolName: "questionmark", accessibilityDescription: nil)
            glyphView.symbolConfiguration = cfg
            glyphView.contentTintColor = NSColor(white: 0.45, alpha: 1)
        }
        glyphView.imageScaling = .scaleProportionallyDown
        glyphView.translatesAutoresizingMaskIntoConstraints = false

        let arrowLabel = NSTextField(labelWithString: "→")
        arrowLabel.font = .systemFont(ofSize: 10, weight: .regular)
        arrowLabel.textColor = NSColor(white: 0.38, alpha: 1)
        arrowLabel.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel.font = .systemFont(ofSize: 11, weight: .medium)
        summaryLabel.textColor = NSColor(white: 0.72, alpha: 1)
        summaryLabel.maximumNumberOfLines = 1
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let chevronButton = NSButton(title: "⌄", target: self, action: #selector(tappedChevron))
        chevronButton.isBordered = false
        chevronButton.font = .systemFont(ofSize: 11, weight: .regular)
        chevronButton.contentTintColor = NSColor(white: 0.45, alpha: 1)
        chevronButton.translatesAutoresizingMaskIntoConstraints = false

        translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyphView)
        addSubview(arrowLabel)
        addSubview(summaryLabel)
        addSubview(chevronButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),

            glyphView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            glyphView.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyphView.widthAnchor.constraint(equalToConstant: 18),
            glyphView.heightAnchor.constraint(equalToConstant: 18),

            arrowLabel.leadingAnchor.constraint(equalTo: glyphView.trailingAnchor, constant: 6),
            arrowLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            summaryLabel.leadingAnchor.constraint(equalTo: arrowLabel.trailingAnchor, constant: 6),
            summaryLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            summaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevronButton.leadingAnchor, constant: -4),

            chevronButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            chevronButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevronButton.widthAnchor.constraint(equalToConstant: 16)
        ])
    }

    func updateSummary(_ text: String) {
        summaryLabel.stringValue = text.isEmpty ? "—" : text
    }

    @objc private func tappedChevron() {
        onChevronClicked?()
    }
}

// MARK: - BindingEditorController

final class BindingEditorController: NSViewController {
    var controllerButton: ControllerButton = .buttonA
    var profileMappings: [ButtonGesture: [Action]] = [:]
    var onBindingChanged: ((ButtonGesture, [Action]?) -> Void)?

    private var selectedKind: PressKind = .press
    private var capturedStroke: KeyStroke?
    private var selectedAppPath: String?
    private var keyMonitor: Any?

    private let gestureSC = NSSegmentedControl()
    private let currentBindingLabel = NSTextField(labelWithString: "—")
    private let actionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let keyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let cmdCheck  = NSButton(checkboxWithTitle: "⌘", target: nil, action: nil)
    private let optCheck  = NSButton(checkboxWithTitle: "⌥", target: nil, action: nil)
    private let ctlCheck  = NSButton(checkboxWithTitle: "⌃", target: nil, action: nil)
    private let shfCheck  = NSButton(checkboxWithTitle: "⇧", target: nil, action: nil)
    private let recordBtn = NSButton(title: "录制", target: nil, action: nil)
    private let appBtn    = NSButton(title: "选择 App", target: nil, action: nil)
    private let appLabel  = NSTextField(labelWithString: "未选择")
    private let clearBtn  = NSButton(title: "清空", target: nil, action: nil)
    private let saveBtn   = NSButton(title: "保存", target: nil, action: nil)

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 330))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedRed: 0.09, green: 0.11, blue: 0.16, alpha: 1).cgColor
        buildUI()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        stopRecording()
    }

    private func buildUI() {
        let titleLabel = NSTextField(labelWithString: controllerButton.displayName)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let kinds = PressKind.allCases
        gestureSC.segmentCount = kinds.count
        for (i, k) in kinds.enumerated() {
            gestureSC.setLabel(k.displayName, forSegment: i)
        }
        gestureSC.selectedSegment = PressKind.allCases.firstIndex(of: .press) ?? 0
        gestureSC.target = self
        gestureSC.action = #selector(gestureChanged)
        gestureSC.controlSize = .small
        gestureSC.translatesAutoresizingMaskIntoConstraints = false

        currentBindingLabel.font = .systemFont(ofSize: 11, weight: .regular)
        currentBindingLabel.textColor = NSColor(white: 0.6, alpha: 1)
        currentBindingLabel.maximumNumberOfLines = 1
        currentBindingLabel.translatesAutoresizingMaskIntoConstraints = false

        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false

        setupActionPopup()
        setupKeyPopup()
        [cmdCheck, optCheck, ctlCheck, shfCheck].forEach {
            $0.contentTintColor = .labelColor
            $0.target = self
            $0.action = #selector(modifierChanged)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        recordBtn.target = self
        recordBtn.action = #selector(toggleRecording)
        appBtn.target = self
        appBtn.action = #selector(chooseApp)
        appLabel.font = .systemFont(ofSize: 10)
        appLabel.textColor = NSColor(white: 0.55, alpha: 1)
        appLabel.maximumNumberOfLines = 1
        appLabel.lineBreakMode = .byTruncatingMiddle
        appLabel.translatesAutoresizingMaskIntoConstraints = false

        clearBtn.target = self
        clearBtn.action = #selector(clearAction)
        saveBtn.target = self
        saveBtn.action = #selector(saveAction)
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"

        [actionPopup, keyPopup].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.widthAnchor.constraint(equalToConstant: 200).isActive = true
        }
        [recordBtn, appBtn, clearBtn, saveBtn].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }

        let modRow = NSStackView(views: [cmdCheck, optCheck, ctlCheck, shfCheck, recordBtn])
        modRow.spacing = 8
        modRow.translatesAutoresizingMaskIntoConstraints = false

        let appRow = NSStackView(views: [appBtn, appLabel])
        appRow.spacing = 8
        appRow.translatesAutoresizingMaskIntoConstraints = false

        let bottomRow = NSStackView(views: [clearBtn, NSView(), saveBtn])
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 8
        (bottomRow.arrangedSubviews[1] as NSView).setContentHuggingPriority(.defaultLow, for: .horizontal)
        bottomRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let actionLabel = NSTextField(labelWithString: "绑定功能")
        actionLabel.font = .systemFont(ofSize: 11)
        actionLabel.textColor = NSColor(white: 0.55, alpha: 1)

        let keyLabel = NSTextField(labelWithString: "快捷键")
        keyLabel.font = .systemFont(ofSize: 11)
        keyLabel.textColor = NSColor(white: 0.55, alpha: 1)

        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(gestureSC)
        stack.addArrangedSubview(currentBindingLabel)
        stack.addArrangedSubview(sep)
        stack.addArrangedSubview(actionLabel)
        stack.addArrangedSubview(actionPopup)
        stack.addArrangedSubview(keyLabel)
        stack.addArrangedSubview(keyPopup)
        stack.addArrangedSubview(modRow)
        stack.addArrangedSubview(appRow)
        stack.addArrangedSubview(bottomRow)

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor),
            sep.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            bottomRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            gestureSC.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32)
        ])

        // Pre-select the gesture kind that already has a binding for this button
        let bindingPriority: [PressKind] = [.press, .singleClick, .doubleClick, .longPress, .release]
        for kind in bindingPriority {
            if profileMappings[ButtonGesture(button: controllerButton, kind: kind)] != nil,
               let idx = PressKind.allCases.firstIndex(of: kind) {
                gestureSC.selectedSegment = idx
                break
            }
        }

        reloadForCurrentGesture()
    }

    private func setupActionPopup() {
        [
            ("无绑定", ActionKind.none.rawValue),
            ("快捷键", ActionKind.shortcut.rawValue),
            ("鼠标左键", ActionKind.mouseLeft.rawValue),
            ("鼠标右键", ActionKind.mouseRight.rawValue),
            ("鼠标中键", ActionKind.mouseMiddle.rawValue),
            ("程序切换", ActionKind.appSwitch.rawValue),
            ("打开应用", ActionKind.openApplication.rawValue)
        ].forEach { title, value in
            actionPopup.addItem(withTitle: title)
            actionPopup.lastItem?.representedObject = value
        }
        actionPopup.target = self
        actionPopup.action = #selector(actionTypeChanged)
    }

    private func setupKeyPopup() {
        for option in KeyCatalog.options {
            keyPopup.addItem(withTitle: option.title)
            keyPopup.lastItem?.representedObject = option.keyCode
        }
        keyPopup.target = self
        keyPopup.action = #selector(keyChanged)
    }

    @objc private func gestureChanged() {
        reloadForCurrentGesture()
    }

    private func reloadForCurrentGesture() {
        let gesture = currentGesture()
        let actions = profileMappings[gesture] ?? []
        let summary = summaryFor(actions: actions)
        currentBindingLabel.stringValue = summary.isEmpty ? "—" : summary
        capturedStroke = nil
        selectedAppPath = nil
        let first = actions.first
        let kind = first?.supportedActionKind ?? .none
        selectActionKind(kind)
        switch first {
        case .keyStroke(let stroke):
            applyStroke(stroke)
        case .openApplication(let path):
            selectedAppPath = path
            appLabel.stringValue = (path as NSString).lastPathComponent
        default:
            appLabel.stringValue = "未选择"
        }
        updateControlVisibility()
    }

    @objc private func actionTypeChanged() {
        if currentActionKind() == .appSwitch {
            let stroke = appSwitchStroke()
            capturedStroke = stroke
            applyStroke(stroke)
        }
        updateControlVisibility()
    }

    @objc private func keyChanged() {
        guard currentActionKind() == .shortcut else { return }
        capturedStroke = selectedFallbackStroke()
    }

    @objc private func modifierChanged() {
        guard currentActionKind() == .shortcut else { return }
        capturedStroke = selectedFallbackStroke()
    }

    @objc private func toggleRecording() {
        if keyMonitor != nil {
            stopRecording()
            return
        }
        recordBtn.title = "按下快捷键…"
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.captureEvent(event)
            return nil
        }
    }

    private func captureEvent(_ event: NSEvent) {
        guard event.keyCode != 53 else { stopRecording(); return }
        let mods = modifiersFrom(event.modifierFlags)
        let stroke = KeyStroke(keyCode: UInt16(event.keyCode), modifiers: mods)
        capturedStroke = stroke
        applyStroke(stroke)
        selectActionKind(.shortcut)
        currentBindingLabel.stringValue = KeyCatalog.describe(stroke)
        stopRecording()
    }

    private func stopRecording() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        recordBtn.title = "录制"
    }

    @objc private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectedAppPath = url.path
        appLabel.stringValue = url.lastPathComponent
        selectActionKind(.openApplication)
        updateControlVisibility()
    }

    @objc private func clearAction() {
        onBindingChanged?(currentGesture(), nil)
        profileMappings.removeValue(forKey: currentGesture())
        reloadForCurrentGesture()
    }

    @objc private func saveAction() {
        let gesture = currentGesture()
        let actions: [Action]?
        switch currentActionKind() {
        case .none:
            actions = nil
        case .shortcut:
            actions = [.keyStroke(capturedStroke ?? selectedFallbackStroke())]
        case .mouseLeft:
            actions = [.mouseClick(.left)]
        case .mouseRight:
            actions = [.mouseClick(.right)]
        case .mouseMiddle:
            actions = [.mouseClick(.middle)]
        case .appSwitch:
            actions = [.keyStroke(appSwitchStroke())]
        case .openApplication:
            guard let path = selectedAppPath else { NSSound.beep(); return }
            actions = [.openApplication(path)]
        }
        onBindingChanged?(gesture, actions)
        profileMappings[gesture] = actions
        reloadForCurrentGesture()
    }

    private func updateControlVisibility() {
        let kind = currentActionKind()
        let isShortcut = kind == .shortcut || kind == .appSwitch
        keyPopup.isHidden = !isShortcut
        [cmdCheck, optCheck, ctlCheck, shfCheck, recordBtn].forEach { $0.isEnabled = isShortcut }
        appBtn.isHidden = kind != .openApplication
        appLabel.isHidden = kind != .openApplication
    }

    private func currentGesture() -> ButtonGesture {
        ButtonGesture(button: controllerButton, kind: currentKind())
    }

    private func currentKind() -> PressKind {
        let idx = gestureSC.selectedSegment
        return PressKind.allCases.indices.contains(idx) ? PressKind.allCases[idx] : .press
    }

    private func currentActionKind() -> ActionKind {
        guard let raw = actionPopup.selectedItem?.representedObject as? String,
              let kind = ActionKind(rawValue: raw) else { return .none }
        return kind
    }

    private func selectActionKind(_ kind: ActionKind) {
        for i in 0..<actionPopup.numberOfItems where actionPopup.item(at: i)?.representedObject as? String == kind.rawValue {
            actionPopup.selectItem(at: i)
            return
        }
    }

    private func selectedFallbackStroke() -> KeyStroke {
        let code = keyPopup.selectedItem?.representedObject as? UInt16 ?? KeyCatalog.tabCode
        return KeyStroke(keyCode: code, modifiers: selectedModifiers())
    }

    private func selectedModifiers() -> [KeyModifier] {
        var mods: [KeyModifier] = []
        if cmdCheck.state == .on { mods.append(.command) }
        if optCheck.state == .on { mods.append(.option) }
        if ctlCheck.state == .on { mods.append(.control) }
        if shfCheck.state == .on { mods.append(.shift) }
        return mods
    }

    private func modifiersFrom(_ flags: NSEvent.ModifierFlags) -> [KeyModifier] {
        var mods: [KeyModifier] = []
        if flags.contains(.command) { mods.append(.command) }
        if flags.contains(.option)  { mods.append(.option) }
        if flags.contains(.control) { mods.append(.control) }
        if flags.contains(.shift)   { mods.append(.shift) }
        return mods
    }

    private func applyStroke(_ stroke: KeyStroke) {
        capturedStroke = stroke
        cmdCheck.state = stroke.modifiers.contains(.command) ? .on : .off
        optCheck.state = stroke.modifiers.contains(.option)  ? .on : .off
        ctlCheck.state = stroke.modifiers.contains(.control) ? .on : .off
        shfCheck.state = stroke.modifiers.contains(.shift)   ? .on : .off
        for i in 0..<keyPopup.numberOfItems where keyPopup.item(at: i)?.representedObject as? UInt16 == stroke.keyCode {
            keyPopup.selectItem(at: i)
            break
        }
    }

    private func appSwitchStroke() -> KeyStroke {
        if controllerButton == .leftShoulder {
            return KeyStroke(keyCode: KeyCatalog.tabCode, modifiers: [.command, .shift])
        }
        return KeyStroke(keyCode: KeyCatalog.tabCode, modifiers: [.command])
    }

    private func summaryFor(actions: [Action]) -> String {
        guard let action = actions.first else { return "—" }
        if actions.count > 1 { return "多动作" }
        switch action {
        case .keyStroke(let stroke): return KeyCatalog.describe(stroke)
        case .mouseClick(.left):  return "鼠标左键"
        case .mouseClick(.right): return "鼠标右键"
        case .mouseClick(.middle): return "鼠标中键"
        case .openApplication(let path): return "打开 " + (path as NSString).lastPathComponent
        default: return "高级动作"
        }
    }
}
