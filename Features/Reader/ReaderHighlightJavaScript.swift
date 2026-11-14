// ReaderHighlightJavaScript.swift
// The page side of saved highlights.
//
// Text selection stays with WebKit: the system selection, handles and edit menu
// are used as they are. The reader only adds its colors to that menu (see
// `ReaderEditMenu`), then paints the saved highlights with the CSS Custom
// Highlight API already used for the spoken word.

import Foundation

enum ReaderHighlightJavaScript {

    /// Nothing but the fill: the text keeps the reader's colour, so the end of
    /// the shimmer is the same pixels as the highlight it settles into.
    static var css: String {
        let colors = ReaderHighlightColor.allCases
            .filter { !$0.isClearSwatch }
            .map { color in
                """
                ::highlight(lnr-hl-\(color.rawValue)) {
                    background-color: \(color.settledFillCSS);
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

        // The palette the native menu offers, in page colours.
        var COLORS = {
            green: { hex: '#5CE680', fill: 'rgba(92,230,128,0.34)', crest: 'rgba(209,255,224,0.95)' },
            skyBlue: { hex: '#54C4FF', fill: 'rgba(84,196,255,0.34)', crest: 'rgba(209,245,255,0.95)' },
            pink: { hex: '#F566B8', fill: 'rgba(245,102,184,0.34)', crest: 'rgba(255,217,233,0.95)' },
            yellow: { hex: '#F5C745', fill: 'rgba(245,199,69,0.34)', crest: 'rgba(255,245,199,0.95)' },
            indigo: { hex: '#6178F7', fill: 'rgba(97,120,247,0.34)', crest: 'rgba(209,219,255,0.95)' },
            purple: { hex: '#9E59F5', fill: 'rgba(158,89,245,0.34)', crest: 'rgba(235,209,255,0.95)' },
            coralRed: { hex: '#EB595C', fill: 'rgba(235,89,92,0.34)', crest: 'rgba(255,209,209,0.95)' },
            clearWhite: { hex: '#FFFFFF', fill: 'rgba(0,0,0,0)', crest: 'rgba(255,255,255,0.95)' }
        };

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
            var block = document.querySelector('[data-tts-index="' + target.paragraphIndex + '"]');
            var rects = [];
            if (block) {
                var range = window.lnrRangeFor(block, target.startOffset, target.endOffset);
                if (range) rects = Array.prototype.slice.call(range.getClientRects());
            }
            var fromColor = colorUnder(target.paragraphIndex, target.startOffset, target.endOffset);
            shimmerSkip = {
                paragraphIndex: target.paragraphIndex,
                startOffset: target.startOffset,
                endOffset: target.endOffset
            };
            window.__lnrShimmerActive = true;
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
            startShimmer(block, rects, fromColor, color);
        };

        var lastHighlights = null;

        // MARK: - Shimmer into the new color

        // While a highlight animates in, the stored highlight for those offsets
        // is held back so the sweep, not the final fill, is seen first.
        var shimmerSkip = null;

        function colorUnder(paragraphIndex, startOffset, endOffset) {
            var color = null;
            (lastHighlights || []).forEach(function(item) {
                if (item.paragraphIndex === paragraphIndex
                    && item.startOffset < endOffset
                    && startOffset < item.endOffset) {
                    color = item.color;
                }
            });
            return color;
        }

        function isClearColor(name) {
            return !name || name === 'clearWhite';
        }

        function buildLines(rects) {
            var lines = [];
            for (var i = 0; i < rects.length; i++) {
                var rect = rects[i];
                if (rect.width < 0.5 || rect.height < 0.5) continue;
                var line = null;
                for (var j = 0; j < lines.length; j++) {
                    var candidate = lines[j];
                    if (Math.abs(candidate.top - rect.top) < 4
                        && Math.abs(candidate.bottom - rect.bottom) < 8) {
                        line = candidate;
                        break;
                    }
                }
                if (line) {
                    line.left = Math.min(line.left, rect.left);
                    line.right = Math.max(line.right, rect.right);
                    line.top = Math.min(line.top, rect.top);
                    line.bottom = Math.max(line.bottom, rect.bottom);
                } else {
                    lines.push({
                        left: rect.left,
                        right: rect.right,
                        top: rect.top,
                        bottom: rect.bottom
                    });
                }
            }
            lines.sort(function(a, b) { return a.top - b.top || a.left - b.left; });
            return lines;
        }

        var shimmer = {
            nodes: [],
            animations: [],
            timeout: 0,
            block: null,
            position: '',
            positionChanged: false
        };

        function removeShimmer() {
            if (shimmer.timeout) {
                clearTimeout(shimmer.timeout);
                shimmer.timeout = 0;
            }
            for (var i = 0; i < shimmer.animations.length; i++) {
                try { shimmer.animations[i].cancel(); } catch (error) { }
            }
            shimmer.animations = [];
            for (var j = 0; j < shimmer.nodes.length; j++) {
                var node = shimmer.nodes[j];
                if (node.parentNode) node.parentNode.removeChild(node);
            }
            shimmer.nodes = [];
            if (shimmer.positionChanged && shimmer.block) {
                shimmer.block.style.position = shimmer.position;
            }
            shimmer.block = null;
            shimmer.positionChanged = false;
        }

        function finishShimmer() {
            removeShimmer();
            shimmerSkip = null;
            window.__lnrShimmerActive = false;
            window.lnrRefreshHighlights();
            // Let bionic reading apply the paragraphs it held back.
            document.dispatchEvent(new Event('selectionchange'));
        }

        function startShimmer(block, rects, fromName, toName) {
            removeShimmer();
            var to = COLORS[toName];
            if (!block || !rects.length || !to || !Element.prototype.animate) {
                shimmerSkip = null;
                window.__lnrShimmerActive = false;
                window.lnrRefreshHighlights();
                return;
            }
            var from = COLORS[fromName] || COLORS.clearWhite;
            var blockRect = block.getBoundingClientRect();
            var lines = buildLines(rects);
            if (!lines.length) {
                shimmerSkip = null;
                window.__lnrShimmerActive = false;
                window.lnrRefreshHighlights();
                return;
            }

            shimmer.block = block;
            if (window.getComputedStyle(block).position === 'static') {
                shimmer.position = block.style.position;
                block.style.position = 'relative';
                shimmer.positionChanged = true;
            }

            var behind = document.createElement('div');
            behind.style.cssText = 'position:absolute;left:0;top:0;right:0;bottom:0;z-index:-1;pointer-events:none;';
            var above = document.createElement('div');
            above.style.cssText = 'position:absolute;left:0;top:0;right:0;bottom:0;z-index:1;pointer-events:none;';
            block.appendChild(behind);
            block.appendChild(above);
            shimmer.nodes.push(behind, above);

            var widths = lines.map(function(line) { return Math.max(line.right - line.left, 35); });
            var totalWidth = widths.reduce(function(sum, value) { return sum + value; }, 0) || 1;
            var cursor = 0;
            var total = 0;
            var ease = 'cubic-bezier(0.22, 0.61, 0.36, 1)';
            var crestWidth = 52;
            var erase = isClearColor(toName);

            lines.forEach(function(line, index) {
                var width = widths[index];
                var start = cursor / totalWidth;
                cursor += width;
                var end = cursor / totalWidth;
                var overlap = lines.length > 1 ? 0.045 : 0;
                start = Math.max(0, start - (index > 0 ? overlap : 0));
                end = Math.min(1, end + (index < lines.length - 1 ? overlap : 0));
                var delay = start * 560;
                var duration = Math.max((end - start) * 560, 90);
                total = Math.max(total, delay + duration);

                var x = line.left - blockRect.left;
                var y = line.top - blockRect.top;
                var w = line.right - line.left;
                var h = line.bottom - line.top;

                var cell = document.createElement('div');
                cell.style.cssText = 'position:absolute;overflow:hidden;border-radius:4.5px;'
                    + 'left:' + x + 'px;top:' + y + 'px;width:' + w + 'px;height:' + h + 'px;';

                var oldFill = document.createElement('div');
                oldFill.style.cssText = 'position:absolute;left:0;top:0;right:0;bottom:0;background:'
                    + from.fill + ';';
                cell.appendChild(oldFill);

                if (!erase) {
                    var newFill = document.createElement('div');
                    newFill.style.cssText = 'position:absolute;left:0;top:0;right:0;bottom:0;background:'
                        + to.fill + ';clip-path:inset(0 100% 0 0);';
                    cell.appendChild(newFill);
                    shimmer.animations.push(newFill.animate(
                        [
                            { clipPath: 'inset(0 100% 0 0)' },
                            { clipPath: 'inset(0 0 0 0)' }
                        ],
                        { duration: duration, delay: delay, easing: ease, fill: 'both' }
                    ));
                } else if (erase) {
                    shimmer.animations.push(oldFill.animate(
                        [
                            { clipPath: 'inset(0 0 0 0)' },
                            { clipPath: 'inset(0 0 0 100%)' }
                        ],
                        { duration: duration, delay: delay, easing: ease, fill: 'both' }
                    ));
                }

                behind.appendChild(cell);

                // A bright band over the glyphs, like the specular crest of a wave.
                var crestCell = document.createElement('div');
                crestCell.style.cssText = 'position:absolute;overflow:hidden;border-radius:4.5px;'
                    + 'mix-blend-mode:plus-lighter;'
                    + 'left:' + x + 'px;top:' + y + 'px;width:' + w + 'px;height:' + h + 'px;';
                var crest = document.createElement('div');
                crest.style.cssText = 'position:absolute;left:0;top:0;width:' + crestWidth + 'px;height:100%;'
                    + 'background:linear-gradient(90deg, rgba(0,0,0,0), ' + to.crest + ', rgba(0,0,0,0));'
                    + 'transform:translateX(-' + crestWidth + 'px);';
                crestCell.appendChild(crest);
                shimmer.animations.push(crest.animate(
                    [
                        { transform: 'translateX(-' + crestWidth + 'px)', opacity: 0 },
                        { opacity: 1, offset: 0.12 },
                        { opacity: 1, offset: 0.88 },
                        { transform: 'translateX(' + w + 'px)', opacity: 0 }
                    ],
                    { duration: duration, delay: delay, easing: ease, fill: 'both' }
                ));
                above.appendChild(crestCell);
            });

            shimmer.timeout = setTimeout(function() {
                shimmer.timeout = 0;
                finishShimmer();
            }, total + 60);
        }

        function paintHighlights(items) {
            if (!(window.CSS && CSS.highlights && window.Highlight)) return;
            for (var i = 0; i < NAMES.length; i++) CSS.highlights.delete('lnr-hl-' + NAMES[i]);
            var groups = {};
            items.forEach(function(item) {
                if (NAMES.indexOf(item.color) < 0) return;
                if (shimmerSkip
                    && item.paragraphIndex === shimmerSkip.paragraphIndex
                    && item.startOffset < shimmerSkip.endOffset
                    && shimmerSkip.startOffset < item.endOffset) return;
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
        }

        window.lnrApplyHighlights = function(json) {
            var items;
            try { items = JSON.parse(json); } catch (e) { return; }
            if (!Array.isArray(items)) return;
            lastHighlights = items;
            paintHighlights(items);
        };

        // Bionic reading rewrites a paragraph's text nodes when it scrolls into
        // view, which invalidates the ranges painted earlier. Rebuild them from
        // the saved offsets once the rewrite is done.
        window.lnrRefreshHighlights = function() {
            if (lastHighlights) paintHighlights(lastHighlights);
        };

        window.__lnrHighlightRefreshPending = false;
        window.lnrScheduleHighlightRefresh = function() {
            if (window.__lnrHighlightRefreshPending) return;
            window.__lnrHighlightRefreshPending = true;
            requestAnimationFrame(function() {
                window.__lnrHighlightRefreshPending = false;
                window.lnrRefreshHighlights();
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

        // Bionic reading splits words into inline elements. WebKit's rich copy
        // serializer drops spaces at those boundaries and carries the <strong>
        // formatting, so copy the selection as plain text instead.
        document.addEventListener('copy', function(event) {
            var selection = window.getSelection();
            if (!selection || selection.rangeCount === 0 || selection.isCollapsed) return;
            if (!event.clipboardData) return;
            event.clipboardData.setData('text/plain', selection.toString());
            event.preventDefault();
        });
    })();
    """#
}
