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
    private let hookStore: HookStore
    private let hookService: HookService
    private let preferences: AppPreferences
    private let onPreferencesChanged: () -> Void

    private var config: BridgeConfig
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
        hookStore: HookStore,
        hookService: HookService,
        preferences: AppPreferences,
        onPreferencesChanged: @escaping () -> Void
    ) {
        self.configStore = configStore
        self.hookStore = hookStore
        self.hookService = hookService
        self.preferences = preferences
        self.onPreferencesChanged = onPreferencesChanged
        self.config = configStore.current
        self.hooks = hookStore.hooks
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "DualSenseKit"
        window.minSize = NSSize(width: 920, height: 560)
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
        selectedButton = config.mappings.keys.first?.button ?? .dpadRight
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
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.white.cgColor
        root.translatesAutoresizingMaskIntoConstraints = false

        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = NSColor(calibratedRed: 0.94, green: 0.95, blue: 0.97, alpha: 1).cgColor
        let sidebarContent = buildSidebar()
        sidebar.addSubview(sidebarContent)

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.wantsLayer = true
        contentContainer.layer?.backgroundColor = NSColor.white.cgColor

        root.addSubview(sidebar)
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
            sidebar.widthAnchor.constraint(equalToConstant: 280),
            contentContainer.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: root.topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
    }

    private func buildSidebar() -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 18
        root.edgeInsets = NSEdgeInsets(top: 28, left: 24, bottom: 24, right: 18)
        root.translatesAutoresizingMaskIntoConstraints = false

        let mark = NSTextField(labelWithString: "logo")
        mark.alignment = .center
        mark.font = .systemFont(ofSize: 15, weight: .semibold)
        mark.textColor = .labelColor
        mark.wantsLayer = true
        mark.layer?.backgroundColor = NSColor(calibratedRed: 0.86, green: 0.89, blue: 0.92, alpha: 1).cgColor
        mark.layer?.cornerRadius = 24
        mark.widthAnchor.constraint(equalToConstant: 48).isActive = true
        mark.heightAnchor.constraint(equalToConstant: 48).isActive = true

        let title = NSTextField(labelWithString: "DSKit")
        title.font = .systemFont(ofSize: 20, weight: .bold)
        title.textColor = .labelColor

        let brandRow = row([mark, NSView(), title])
        brandRow.widthAnchor.constraint(equalToConstant: 230).isActive = true

        mappingNavButton.target = self
        mappingNavButton.action = #selector(showMappingPage)
        hooksNavButton.target = self
        hooksNavButton.action = #selector(showHooksPage)
        settingsNavButton.target = self
        settingsNavButton.action = #selector(showSettingsPage)
        [mappingNavButton, hooksNavButton, settingsNavButton].forEach {
            $0.isBordered = false
            $0.alignment = .left
            $0.font = .systemFont(ofSize: 18, weight: .semibold)
            $0.contentTintColor = .labelColor
            $0.wantsLayer = true
            $0.layer?.cornerRadius = 8
            $0.widthAnchor.constraint(equalToConstant: 226).isActive = true
            $0.heightAnchor.constraint(equalToConstant: 42).isActive = true
        }

        [launchCheck, dockCheck, statusCheck].forEach {
            $0.target = self
            $0.action = #selector(preferencesChanged)
            $0.font = .systemFont(ofSize: 13, weight: .regular)
            $0.contentTintColor = .labelColor
        }

        root.addArrangedSubview(brandRow)
        root.addArrangedSubview(spacer(height: 18))
        root.addArrangedSubview(mappingNavButton)
        root.addArrangedSubview(hooksNavButton)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        root.addArrangedSubview(spacer)
        root.addArrangedSubview(settingsNavButton)

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
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
        [(mappingNavButton, Page.mapping), (hooksNavButton, Page.hooks), (settingsNavButton, Page.settings)].forEach { button, page in
            button.layer?.backgroundColor = currentPage == page
                ? NSColor(calibratedRed: 0.88, green: 0.90, blue: 0.93, alpha: 1).cgColor
                : NSColor.clear.cgColor
        }
    }

    private func buildMappingPage() -> NSView {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.white.cgColor

        let previewContainer = NSView()
        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.wantsLayer = true
        previewContainer.layer?.backgroundColor = NSColor(calibratedWhite: 0.985, alpha: 1).cgColor
        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewView.onSelectButton = { [weak self] button in self?.select(button) }
        previewContainer.addSubview(previewView)

        let inspector = buildMappingInspector()
        inspector.translatesAutoresizingMaskIntoConstraints = false
        inspector.wantsLayer = true
        inspector.layer?.backgroundColor = NSColor.white.cgColor

        root.addSubview(previewContainer)
        root.addSubview(inspector)
        NSLayoutConstraint.activate([
            previewContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            previewContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            previewContainer.topAnchor.constraint(equalTo: root.topAnchor),
            previewContainer.heightAnchor.constraint(equalTo: root.heightAnchor, multiplier: 0.68),
            previewView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: 48),
            previewView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: -48),
            previewView.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 36),
            previewView.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: -36),
            inspector.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            inspector.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            inspector.topAnchor.constraint(equalTo: previewContainer.bottomAnchor),
            inspector.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        return root
    }

    private func buildMappingInspector() -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 22, left: 48, bottom: 22, right: 42)
        root.translatesAutoresizingMaskIntoConstraints = false

        selectedTitle.font = .systemFont(ofSize: 18, weight: .bold)
        selectedTitle.textColor = .labelColor
        summaryLabel.font = .systemFont(ofSize: 12, weight: .regular)
        summaryLabel.textColor = .labelColor
        summaryLabel.maximumNumberOfLines = 3
        advancedLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        advancedLabel.textColor = .systemOrange
        advancedLabel.maximumNumberOfLines = 3

        configureMappingControls()
        let gestureBar = row(PressKind.allCases.map { kind in
            let button = NSButton(title: kind.displayName, target: self, action: #selector(selectGestureFromButton(_:)))
            button.tag = PressKind.allCases.firstIndex(of: kind) ?? 0
            button.bezelStyle = .rounded
            return button
        })
        gestureBar.spacing = 10
        let leftColumn = NSStackView()
        leftColumn.orientation = .vertical
        leftColumn.alignment = .leading
        leftColumn.spacing = 12
        leftColumn.addArrangedSubview(selectedTitle)
        leftColumn.addArrangedSubview(summaryLabel)
        leftColumn.addArrangedSubview(advancedLabel)
        leftColumn.addArrangedSubview(row([label("触发方式", width: 86), gesturePopup]))
        leftColumn.addArrangedSubview(row([label("绑定功能", width: 86), actionPopup]))
        leftColumn.addArrangedSubview(row([label("快捷键", width: 86), keyPopup]))

        let rightColumn = NSStackView()
        rightColumn.orientation = .vertical
        rightColumn.alignment = .leading
        rightColumn.spacing = 12
        rightColumn.addArrangedSubview(row([commandCheck, optionCheck, controlCheck, shiftCheck]))
        rightColumn.addArrangedSubview(row([recordButton, chooseAppButton]))
        appPathLabel.textColor = .labelColor
        rightColumn.addArrangedSubview(appPathLabel)
        rightColumn.addArrangedSubview(row([clearButton, saveButton]))

        let columns = row([leftColumn, rightColumn])
        columns.spacing = 80
        root.addArrangedSubview(gestureBar)
        root.addArrangedSubview(columns)

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor)
        ])
        return container
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

        let add = hookGridCard(title: "+", subtitle: "新建 Hook", color: NSColor(calibratedWhite: 0.96, alpha: 1), index: nil)
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
            NSColor(calibratedRed: 1.00, green: 0.78, blue: 0.78, alpha: 1),
            NSColor(calibratedRed: 0.12, green: 0.70, blue: 0.55, alpha: 1),
            NSColor(calibratedRed: 0.28, green: 0.76, blue: 0.34, alpha: 1),
            NSColor(calibratedRed: 0.91, green: 0.92, blue: 0.95, alpha: 1)
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
            settingsRow(title: "单指轻触点击", control: configToggle(title: "", tag: 10, isOn: config.mappings[ButtonGesture(button: .touchpadOneFingerTap, kind: .singleClick)] != nil)),
            settingsRow(title: "双指轻触右键", control: configToggle(title: "", tag: 16, isOn: config.mappings[ButtonGesture(button: .touchpadTwoFingerTap, kind: .singleClick)] != nil)),
            settingsRow(title: "触控按下模拟鼠标按下", control: configToggle(title: "", tag: 12, isOn: config.mappings[ButtonGesture(button: .touchpadButton, kind: .press)] != nil)),
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
            config.mappings[gesture] = sender.state == .on ? [.mouseClick(.left)] : nil
        case 11:
            config.touchpad.enabled = sender.state == .on
        case 12:
            let gesture = ButtonGesture(button: .touchpadButton, kind: .press)
            config.mappings[gesture] = sender.state == .on ? [.mouseClick(.left)] : nil
        case 13:
            config.touchpad.scrollSensitivity = sender.state == .on ? 14 : 0
        case 16:
            let gesture = ButtonGesture(button: .touchpadTwoFingerTap, kind: .singleClick)
            config.mappings[gesture] = sender.state == .on ? [.mouseClick(.right)] : nil
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
        let result = hookService.execute(hook)
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
        let actions = config.mappings[gesture] ?? []
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
        config.mappings[currentGesture()] = nil
        configStore.save(config)
        loadSelection()
    }

    @objc private func saveBinding() {
        let gesture = currentGesture()
        switch currentActionKind() {
        case .none:
            config.mappings[gesture] = nil
        case .shortcut:
            config.mappings[gesture] = [.keyStroke(capturedStroke ?? selectedFallbackStroke())]
        case .mouseLeft:
            config.mappings[gesture] = [.mouseClick(.left)]
        case .mouseRight:
            config.mappings[gesture] = [.mouseClick(.right)]
        case .mouseMiddle:
            config.mappings[gesture] = [.mouseClick(.middle)]
        case .appSwitch:
            config.mappings[gesture] = [.keyStroke(appSwitchStroke())]
        case .openApplication:
            guard let selectedApplicationPath else {
                NSSound.beep()
                return
            }
            config.mappings[gesture] = [.openApplication(selectedApplicationPath)]
        }
        configStore.save(config)
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
