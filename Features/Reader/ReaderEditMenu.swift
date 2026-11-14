// ReaderEditMenu.swift
// Adds the highlight palette to WebKit's own text-selection menu.
//
// UIKit builds that menu from `UITextInput.editMenuForTextRange:suggestedActions:`
// and falls back to copying when nobody implements it. `WKContentView` is the
// text input but does not implement the method, so this adds it to WebKit's
// class at runtime and returns the system's suggestions with a colour menu
// appended. An implementation WebKit adds in future is called first.

import ObjectiveC
import UIKit
import WebKit
import os

@MainActor
enum ReaderEditMenu {

    private static var readerKey: UInt8 = 0
    private static var injectedClasses = Set<ObjectIdentifier>()

    private static let selector = NSSelectorFromString("editMenuForTextRange:suggestedActions:")

    private static let log = Logger(subsystem: "com.lnreader", category: "reader")

    /// Marks this web view as a reader (so only its menu gains colours) and
    /// makes sure the editing class answers the menu method. Safe to repeat.
    static func installIfNeeded(in webView: WKWebView) {
        objc_setAssociatedObject(webView, &readerKey, NSNumber(value: true), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        guard let type = contentViewClass(in: webView) else { return }
        let identity = ObjectIdentifier(type)
        guard !injectedClasses.contains(identity) else { return }
        injectedClasses.insert(identity)
        injectMenuMethod(into: type)
    }

    private static func contentViewClass(in webView: WKWebView) -> AnyClass? {
        // The class is private but stable; finding an instance is the fallback.
        if let type = NSClassFromString("WKContentView") { return type }
        guard let contentView = findContentView(webView) else { return nil }
        return object_getClass(contentView)
    }

    private static func injectMenuMethod(into type: AnyClass) {
        let original = class_getInstanceMethod(type, selector).map(method_getImplementation)

        let block: @convention(block) (UIView, UITextRange, [UIMenuElement]) -> UIMenu? = { view, range, suggested in
            MainActor.assumeIsolated {
                guard let webView = enclosingWebView(of: view),
                      objc_getAssociatedObject(webView, &readerKey) != nil else {
                    return call(original, on: view, range: range, suggested: suggested)
                }
                let base = call(original, on: view, range: range, suggested: suggested)
                var children = base?.children ?? suggested
                children.append(highlightMenu(for: view))
                return UIMenu(title: base?.title ?? "", options: base?.options ?? [], children: children)
            }
        }

        let implementation = imp_implementationWithBlock(block)
        let types = "@@:@@"
        if class_getInstanceMethod(type, selector) == nil {
            class_addMethod(type, selector, implementation, types)
        } else {
            class_replaceMethod(type, selector, implementation, types)
        }

        #if DEBUG
            log.debug("Edit menu added to \(NSStringFromClass(type), privacy: .public)")
        #endif
    }

    private typealias EditMenuImplementation =
        @convention(c) (AnyObject, Selector, UITextRange, [UIMenuElement]) -> UIMenu?

    private static func call(
        _ implementation: IMP?,
        on view: UIView,
        range: UITextRange,
        suggested: [UIMenuElement]
    ) -> UIMenu? {
        guard let implementation else { return nil }
        return unsafeBitCast(implementation, to: EditMenuImplementation.self)(
            view, selector, range, suggested
        )
    }

    private static func highlightMenu(for view: UIView) -> UIMenu {
        let actions = ReaderHighlightColor.allCases.map { color in
            UIAction(title: color.displayName, image: swatchImage(for: color)) { [weak view] _ in
                guard let view else { return }
                MainActor.assumeIsolated { apply(color, in: view) }
            }
        }
        return UIMenu(
            title: "Highlight",
            image: UIImage(systemName: "highlighter"),
            children: actions
        )
    }

    private static func apply(_ color: ReaderHighlightColor, in view: UIView) {
        Haptics.shared.impact(.light)
        guard let webView = enclosingWebView(of: view) else { return }
        webView.evaluateJavaScript(
            "window.lnrRequestHighlight && window.lnrRequestHighlight('\(color.rawValue)')"
        )
    }

    private static func enclosingWebView(of view: UIView) -> WKWebView? {
        var current: UIView? = view
        while let candidate = current {
            if let webView = candidate as? WKWebView { return webView }
            current = candidate.superview
        }
        return nil
    }

    private static func findContentView(_ view: UIView) -> UIView? {
        if String(describing: type(of: view)).hasPrefix("WKContentView") { return view }
        for subview in view.subviews {
            if let found = findContentView(subview) { return found }
        }
        return nil
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
