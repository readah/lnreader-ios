// ReaderHighlightJavaScript.swift
// The page side of saved highlights.
//
// Text selection stays with WebKit: the system selection, handles and edit menu
// are used as they are. The reader only adds its colors to that menu (see
// `ReaderEditMenu`), then paints the saved highlights with the CSS Custom
// Highlight API already used for the spoken word.

import Foundation

enum ReaderHighlightJavaScript {

    /// Styles that must exist before the first paint: the six stored colors.
    static var css: String {
        let colors = ReaderHighlightColor.allCases
            .filter { !$0.isClearSwatch }
            .map { color in
                """
                ::highlight(lnr-hl-\(color.rawValue)) {
                    background-color: \(color.settledFillCSS);
                    color: \(color.hex);
                    text-decoration: underline;
                    text-decoration-color: \(color.hex);
                    text-decoration-thickness: 1.5px;
                }
                """
            }
            .joined(separator: "\n")

        return colors
    }

    static let source = #"""
    (function() {
        if (window.__lnrHighlightInstalled) return;
        window.__lnrHighlightInstalled = true;

        var NAMES = ['green', 'skyBlue', 'pink', 'yellow', 'indigo', 'purple', 'coralRed'];

        function post(name, payload) {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[name]) {
                window.webkit.messageHandlers[name].postMessage(payload);
            }
        }

        function textNodes(block) {
            var walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT, null);
            var nodes = [], node;
            while ((node = walker.nextNode())) nodes.push(node);
            return nodes;
        }

        function totalLength(block) {
            return block.textContent.length;
        }

        // Character offset of a DOM point inside the block's textContent.
        function offsetFor(block, container, offset) {
            try {
                var range = document.createRange();
                range.setStart(block, 0);
                range.setEnd(container, offset);
                return range.toString().length;
            } catch (e) {
                return 0;
            }
        }

        function pointFor(block, target) {
            var nodes = textNodes(block);
            if (!nodes.length) return null;
            if (target <= 0) return { node: nodes[0], offset: 0 };
            var seen = 0;
            for (var i = 0; i < nodes.length; i++) {
                var length = nodes[i].nodeValue.length;
                if (target <= seen + length) return { node: nodes[i], offset: target - seen };
                seen += length;
            }
            var last = nodes[nodes.length - 1];
            return { node: last, offset: last.nodeValue.length };
        }

        // Range for raw [start, end) offsets into the block's textContent.
        window.lnrRangeFor = function(block, start, end) {
            var length = totalLength(block);
            start = Math.max(0, Math.min(start, length));
            end = Math.max(0, Math.min(end, length));
            if (end < start) { var swap = start; start = end; end = swap; }
            var a = pointFor(block, start);
            var b = pointFor(block, end);
            if (!a || !b) return null;
            var range = document.createRange();
            try {
                range.setStart(a.node, a.offset);
                range.setEnd(b.node, b.offset);
            } catch (e) {
                return null;
            }
            return range;
        };

        // The selection a color action applies to. Kept as a fallback because
        // dismissing the system menu may clear the live selection first.
        var lastSelection = null;

        function captureSelection() {
            var selection = window.getSelection();
            if (!selection || selection.rangeCount === 0 || selection.isCollapsed) return null;
            var range = selection.getRangeAt(0);
            var node = range.startContainer;
            var element = node.nodeType === 1 ? node : node.parentElement;
            var block = element && element.closest('[data-tts-index]');
            if (!block || block.closest('#lnw-comments-section')) return null;
            var paragraphIndex = Number(block.getAttribute('data-tts-index'));
            if (paragraphIndex < 0) return null;
            var start = offsetFor(block, range.startContainer, range.startOffset);
            var end = Math.min(start + range.toString().length, totalLength(block));
            if (end <= start) return null;
            lastSelection = {
                text: block.textContent.substring(start, end),
                paragraphIndex: paragraphIndex,
                startOffset: start,
                endOffset: end
            };
            return lastSelection;
        }

        // Called by the color action in the native selection menu.
        window.lnrRequestHighlight = function(color) {
            var target = captureSelection() || lastSelection;
            if (!target) return;
            post('readerHighlightRequest', JSON.stringify({
                color: color,
                text: target.text,
                paragraphIndex: target.paragraphIndex,
                startOffset: target.startOffset,
                endOffset: target.endOffset
            }));
            var selection = window.getSelection();
            if (selection) selection.removeAllRanges();
            lastSelection = null;
        };

        window.lnrApplyHighlights = function(json) {
            if (!(window.CSS && CSS.highlights && window.Highlight)) return;
            for (var i = 0; i < NAMES.length; i++) CSS.highlights.delete('lnr-hl-' + NAMES[i]);
            var items;
            try { items = JSON.parse(json); } catch (e) { return; }
            if (!Array.isArray(items)) return;
            var groups = {};
            items.forEach(function(item) {
                if (NAMES.indexOf(item.color) < 0) return;
                var block = document.querySelector('[data-tts-index="' + item.paragraphIndex + '"]');
                if (!block) return;
                var range = window.lnrRangeFor(block, item.startOffset, item.endOffset);
                if (!range || range.collapsed) return;
                (groups[item.color] = groups[item.color] || []).push(range);
            });
            Object.keys(groups).forEach(function(color) {
                if (groups[color].length) {
                    CSS.highlights.set('lnr-hl-' + color, new Highlight(...groups[color]));
                }
            });
        };

        /// A short wash over a paragraph, used when a bookmark jumps here.
        window.lnrFlashParagraph = function(index) {
            var block = document.querySelector('[data-tts-index="' + index + '"]');
            if (!block) return;
            var rect = block.getBoundingClientRect();
            var marker = document.createElement('div');
            marker.setAttribute('aria-hidden', 'true');
            marker.style.cssText = 'position:fixed;pointer-events:none;border-radius:6px;z-index:5;'
                + 'background:rgba(255,255,255,0.13);transition:opacity .55s ease;'
                + 'left:' + (rect.left - 4) + 'px;top:' + (rect.top - 2) + 'px;'
                + 'width:' + (rect.width + 8) + 'px;height:' + (rect.height + 4) + 'px;';
            document.body.appendChild(marker);
            setTimeout(function() { marker.style.opacity = 0; }, 420);
            setTimeout(function() { marker.remove(); }, 1100);
        };

        // The native edit menu is presented by WebKit. This tells Swift to make
        // sure the color actions have been installed on its interaction before
        // the menu is built.
        document.addEventListener('selectionchange', function() {
            captureSelection();
            post('readerSelectionChanged', '');
        });
    })();
    """#
}
