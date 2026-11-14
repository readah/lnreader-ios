// ReaderEditMenu.swift
// Adds the highlight palette to WebKit's own text-selection menu.
//
// UIKit has no public hook for the edit menu's contents: `WKUIDelegate` only
// exposes the present/dismiss animators. The menu belongs to a private
// `WKContentView`'s `UIEditMenuInteraction`, so this adopts that interaction's
// delegate and forwards every call it does not handle back to WebKit.

import ObjectiveC
import UIKit
import WebKit

@MainActor
enum ReaderEditMenu {

    /// Called after a load and whenever the page selection changes. A no-op
    /// once the menu has been adopted; safe to call repeatedly.
    static func installIfNeeded(in webView: WKWebView) {
        guard let contentView = findContentView(webView),
              let interaction = findEditMenuInteraction(contentView) else { return }

        if let existing = objc_getAssociatedObject(interaction, &delegateKey) as? EditMenuDelegate {
            if interaction.delegate === existing { return }
            // Keep WebKit's original delegate; only replace it again.
            if let current = interaction.delegate { existing.forwarding = current }
            adopt(existing, in: interaction)
            return
        }

        let delegate = EditMenuDelegate(webView: webView)
        delegate.forwarding = interaction.delegate
        objc_setAssociatedObject(interaction, &delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        adopt(delegate, in: interaction)
    }

    private static var delegateKey: UInt8 = 0

    /// `delegate` is read-only in the public header; the interaction still
    /// stores it in an ivar, so KVC can replace it.
    private static func adopt(_ delegate: EditMenuDelegate, in interaction: UIEditMenuInteraction) {
        let type: AnyClass = type(of: interaction)
        let hasBackingStore = class_getInstanceVariable(type, "_delegate") != nil
            || class_getInstanceVariable(type, "delegate") != nil
        // Without direct ivar access KVC would throw; leave WebKit alone then.
        let allowsIvarAccess = (type as? NSObject.Type)?.accessInstanceVariablesDirectly ?? true
        guard hasBackingStore, allowsIvarAccess else { return }
        interaction.setValue(delegate, forKey: "delegate")
    }

    private static func findContentView(_ view: UIView) -> UIView? {
        if String(describing: type(of: view)).hasPrefix("WKContentView") { return view }
        for subview in view.subviews {
            if let found = findContentView(subview) { return found }
        }
        return nil
    }

    private static func findEditMenuInteraction(_ view: UIView) -> UIEditMenuInteraction? {
        for interaction in view.interactions {
            if let edit = interaction as? UIEditMenuInteraction { return edit }
        }
        for subview in view.subviews {
            if let found = findEditMenuInteraction(subview) { return found }
        }
        return nil
    }
}

/// Forwards WebKit's own edit-menu answers, adding one submenu of colors.
@MainActor
private final class EditMenuDelegate: NSObject, @preconcurrency UIEditMenuInteractionDelegate {

    weak var webView: WKWebView?
    weak var forwarding: UIEditMenuInteractionDelegate?

    init(webView: WKWebView) {
        self.webView = webView
    }

    private lazy var highlightMenu: UIMenu = {
        let actions = ReaderHighlightColor.allCases.map { color in
            UIAction(title: color.displayName, image: Self.swatchImage(for: color)) { [weak self] _ in
                self?.apply(color)
            }
        }
        return UIMenu(
            title: "Highlight",
            image: UIImage(systemName: "highlighter"),
            children: actions
        )
    }()

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        let base = forwarding?.editMenuInteraction?(
            interaction,
            menuFor: configuration,
            suggestedActions: suggestedActions
        )
        var children = base?.children ?? suggestedActions
        children.append(highlightMenu)
        return UIMenu(title: base?.title ?? "", options: base?.options ?? [], children: children)
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (forwarding?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let forwarding, forwarding.responds(to: aSelector) { return forwarding }
        return super.forwardingTarget(for: aSelector)
    }

    private func apply(_ color: ReaderHighlightColor) {
        Haptics.shared.impact(.light)
        webView?.evaluateJavaScript(
            "window.lnrRequestHighlight && window.lnrRequestHighlight('\(color.rawValue)')"
        )
    }

    /// A filled circle for the menu row. Menu images are tinted by default;
    /// `alwaysOriginal` keeps the swatch's actual color.
    private static func swatchImage(for color: ReaderHighlightColor) -> UIImage {
        let size = CGSize(width: 20, height: 20)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1.5, dy: 1.5)
            let circle = UIBezierPath(ovalIn: rect)
            (UIColor(hex: color.hex) ?? .white).setFill()
            circle.fill()
            UIColor.black.withAlphaComponent(color.isClearSwatch ? 0.4 : 0.18).setStroke()
            circle.lineWidth = 1
            circle.stroke()
            if color.isClearSwatch {
                let slash = UIBezierPath()
                slash.move(to: CGPoint(x: rect.minX + 3, y: rect.maxY - 3))
                slash.addLine(to: CGPoint(x: rect.maxX - 3, y: rect.minY + 3))
                slash.lineWidth = 1.5
                slash.stroke()
            }
        }
        return image.withRenderingMode(.alwaysOriginal)
    }
}
