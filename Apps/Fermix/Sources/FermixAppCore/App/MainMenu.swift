import AppKit

/// The real `NSMenu` main menu, built from `CommandTable` (M34 §3.3).
///
/// Titles and enablement are read back from the router every time a menu is
/// about to open, so a toggling item never shows the state it is already in and
/// a command whose condition has lapsed is dimmed rather than silently ignored.
@MainActor
public final class MainMenuController: NSObject, NSMenuItemValidation, NSMenuDelegate {
    private let router: any CommandPerforming

    public init(router: any CommandPerforming) {
        self.router = router
    }

    /// Installs the whole menu bar. Called once, before the first window.
    public func install(into application: NSApplication) {
        let bar = NSMenu()

        for menu in CommandTable.mainMenu {
            let submenu = NSMenu(title: ProductStrings[menu.titleKey])
            submenu.delegate = self
            submenu.autoenablesItems = true
            fill(submenu, with: menu.entries, application: application)

            let holder = NSMenuItem()
            holder.submenu = submenu
            bar.addItem(holder)

            assign(submenu, titled: menu.titleKey, to: application)
        }

        application.mainMenu = bar
    }

    /// The three submenus macOS itself populates or targets.
    private func assign(_ submenu: NSMenu, titled key: ProductStringKey, to application: NSApplication) {
        switch key {
        case .menuTitleWindow: application.windowsMenu = submenu
        case .menuTitleHelpMenu: application.helpMenu = submenu
        default: return
        }
    }

    private func fill(_ menu: NSMenu, with entries: [CommandMenuEntry], application: NSApplication) {
        for entry in entries {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case .servicesMenu:
                let item = NSMenuItem(title: ProductStrings[.menuTitleServices], action: nil, keyEquivalent: "")
                let services = NSMenu()
                item.submenu = services
                application.servicesMenu = services
                menu.addItem(item)
            case .system(let system):
                menu.addItem(Self.menuItem(for: system))
            case .command(let command):
                menu.addItem(item(for: command))
            }
        }
    }

    /// The item a system entry renders as. Not private: the renderer's own
    /// contract — the key equivalent, its modifiers, and the tag the responder
    /// chain reads — is what a menu gate has to inspect.
    static func menuItem(for system: SystemMenuItem) -> NSMenuItem {
        let item = NSMenuItem(
            title: ProductStrings[system.titleKey],
            action: Selector(system.selectorName),
            keyEquivalent: system.keyEquivalent
        )
        var modifiers: NSEvent.ModifierFlags = system.keyEquivalent.isEmpty ? [] : [.command]
        if system.holdsShift { modifiers.insert(.shift) }
        if system.holdsOption { modifiers.insert(.option) }
        item.keyEquivalentModifierMask = modifiers
        // `performTextFinderAction:` reads the tag to know which action it is,
        // and the search field this app has is focused by exactly one of them.
        item.tag = system.tag

        return item
    }

    private func item(for command: AppCommand) -> NSMenuItem {
        let shortcut = CommandTable.shortcut(of: command)
        let item = NSMenuItem(
            title: router.menuTitle(of: command),
            action: #selector(performCommand(_:)),
            keyEquivalent: shortcut?.key ?? ""
        )
        item.target = self
        item.representedObject = command.rawValue

        if let shortcut {
            var modifiers: NSEvent.ModifierFlags = [.command]
            if shortcut.holdsControl { modifiers.insert(.control) }
            if shortcut.holdsShift { modifiers.insert(.shift) }
            item.keyEquivalentModifierMask = modifiers
        }

        return item
    }

    @objc
    private func performCommand(_ sender: NSMenuItem) {
        guard let command = Self.command(of: sender) else { return }

        router.perform(command)
    }

    // MARK: - Live state

    /// A command's item is enabled exactly while the router can perform it.
    /// Everything else is a first-responder item, which AppKit validates.
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let command = Self.command(of: menuItem) else { return true }

        return router.canPerform(command)
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            guard let command = Self.command(of: item) else { continue }

            item.title = router.menuTitle(of: command)
        }
    }

    /// The command an item carries, where it carries one. An item built for a
    /// selector carries none, which is how the two kinds stay distinguishable
    /// without a second list.
    static func command(of item: NSMenuItem) -> AppCommand? {
        guard let raw = item.representedObject as? String else { return nil }

        return AppCommand(rawValue: raw)
    }
}
