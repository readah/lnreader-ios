import Foundation

enum ReaderTTSJavaScript {
    // The paragraph class is an anchor for following, never a visual highlight.
    static let highlightStyle = """
    .tts-active { background: transparent; box-shadow: none; }
    ::highlight(tts-word) { background-color: transparent; color: inherit; }
    #tts-word-marker { position: absolute; top: 0; left: 0; pointer-events: none; border-radius: 5px; background: var(--reader-highlight, rgba(120,154,135,0.26)); opacity: 0; z-index: 1; transition: transform 180ms cubic-bezier(.22,1.25,.36,1), width 180ms ease-out, height 180ms ease-out; will-change: transform; }
    @media (prefers-reduced-motion: reduce) { #tts-word-marker { transition: none !important; } }
    """

    static let speechLayoutStyle = """
    body.tts-speech-mode { padding-top: var(--reader-top-inset, 156px) !important; padding-bottom: 190px !important; }
    body.tts-speech-mode #line-focus-ruler { display: none !important; }
    """

    static let mapping = #"""
    window.ttsIsAnnotation = function(node) {
        for (var element = node.nodeType === 1 ? node : node.parentElement; element; element = element.parentElement) {
            var type = element.getAttribute('epub:type') || '';
            if (/(?:^|\s)(?:noteref|footnote|endnote|pagebreak)(?:\s|$)/.test(type)) return true;
            if (element.matches('[role="doc-noteref"],[role="doc-footnote"],[role="doc-endnote"],[role="doc-pagebreak"]')) return true;
            if (element.tagName === 'A' && /#(?:fn|footnote|endnote|note|ref)[-_:\d]/i.test(element.getAttribute('href') || '')) return true;
            if (element.tagName === 'SUP' && /^\[?\d{1,4}\]?$/.test(element.textContent.trim()) && element.querySelector('a[href]')) return true;
        }
        return false;
    };
    window.ttsTextMap = function(element) {
        var walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT, {
            acceptNode: function(node) {
                if (node.nodeType === 1) return node.tagName === 'BR' ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP;
                var parent = node.parentElement;
                if (window.ttsIsAnnotation(node)) return NodeFilter.FILTER_REJECT;
                if (parent && parent.closest('script,style,[role="doc-noteref"],[role="doc-pagebreak"],a[href^="#fn"],#lnw-comments-section')) return NodeFilter.FILTER_REJECT;
                return NodeFilter.FILTER_ACCEPT;
            }
        });
        var text = '', map = [], node, pending = null;
        while ((node = walker.nextNode())) {
            if (node.nodeType === 1) { if (text.length && !pending) pending = map[map.length - 1]; continue; }
            for (var i = 0; i < node.nodeValue.length; i++) {
                var character = node.nodeValue[i];
                if (/\s/.test(character)) {
                    if (text.length && !pending) pending = {node: node, offset: i};
                } else {
                    if (pending) { text += ' '; map.push(pending); pending = null; }
                    text += character; map.push({node: node, offset: i});
                }
            }
        }
        return {text: text, map: map};
    };
    window.ttsParagraphNodes = function() {
        var nodes = Array.from(document.querySelectorAll('p,h1,h2,h3,h4,h5,h6,li')).filter(function(node) {
            return !window.ttsIsAnnotation(node) && !node.closest('#lnw-comments-section,nav,script,style,[role="doc-footnote"]') &&
                !(node.tagName === 'LI' && node.querySelector('p,li'));
        });
        if (nodes.length) return nodes;
        var root = document.querySelector('article,main,#chapter-content,.reader-content') || document.body;
        var leaves = Array.from(root.querySelectorAll('div,section')).filter(function(node) {
            return !node.querySelector('div,section') && !node.closest('nav,script,style,#lnw-comments-section');
        });
        return leaves.length ? leaves : [root];
    };
    window.ttsExtractBlocks = function() {
        var blocks = [];
        window.ttsParagraphNodes().forEach(function(node) {
            var text = window.ttsTextMap(node).text;
            node.setAttribute('data-tts-index', text ? String(blocks.length) : '-1');
            if (text) blocks.push(text);
        });
        return blocks;
    };
    """#

    static let interaction = #"""
    window.__ttsFollowing = true;
    window.__ttsSpeechMode = false;
    window.__ttsControlsVisible = true;
    window.__ttsWord = null;
    window.ttsSetFollowing = function(value) {
        if (window.__ttsFollowing === value) return;
        window.__ttsFollowing = value;
        window.webkit.messageHandlers.ttsFollowChanged.postMessage(value);
    };
    window.clearTTSActive = function() {
        window.__ttsWord = null;
        if (window.CSS && CSS.highlights) CSS.highlights.delete('tts-word');
        var marker = document.getElementById('tts-word-marker');
        if (marker) { marker.style.opacity = 0; marker.getAnimations().forEach(function(animation) { animation.cancel(); }); }
        document.querySelectorAll('.tts-active').forEach(function(node) { node.classList.remove('tts-active'); });
        var dot = document.getElementById('tts-dot');
        if (dot) dot.style.opacity = 0;
    };
    window.setTTSSpeechMode = function(value) {
        window.__ttsSpeechMode = value;
        document.body.classList.toggle('tts-speech-mode', value);
        if (!value) window.clearTTSActive();
    };
    window.setTTSControlsVisible = function(value) {
        window.__ttsControlsVisible = value;
        // Chrome visibility changes only the overlay, never document geometry or following.
    };
    window.ttsRange = function(word) {
        var target = document.querySelector('[data-tts-index="' + word.paragraphIndex + '"]');
        if (!target) return null;
        var mapped = window.ttsTextMap(target);
        var start = mapped.map[word.sourceStart], end = mapped.map[word.sourceEnd - 1];
        if (!start || !end) return null;
        var range = document.createRange();
        range.setStart(start.node, start.offset); range.setEnd(end.node, end.offset + 1);
        return {range: range, target: target};
    };
    window.setTTSActiveWord = function(word) {
        if (!window.__ttsSpeechMode || !word) { window.clearTTSActive(); return; }
        var mapped = window.ttsRange(word);
        if (!mapped) { window.clearTTSActive(); return; }
        window.__ttsWord = word;
        var active = document.querySelector('.tts-active');
        if (active && active !== mapped.target) active.classList.remove('tts-active');
        mapped.target.classList.add('tts-active');
        if (window.CSS && CSS.highlights && window.Highlight) CSS.highlights.set('tts-word', new Highlight(mapped.range));
        var rect = mapped.range.getBoundingClientRect();
        var marker = document.getElementById('tts-word-marker');
        if (!marker) { marker = document.createElement('span'); marker.id = 'tts-word-marker'; marker.setAttribute('aria-hidden', 'true'); document.body.appendChild(marker); }
        var body = document.body.getBoundingClientRect();
        var previous = marker.getBoundingClientRect();
        var jump = marker.style.opacity !== '1' || Math.abs(previous.top - rect.top) > rect.height * 1.5 || Math.abs(previous.left - rect.left) > 200;
        marker.style.transitionProperty = jump ? 'none' : '';
        marker.style.width = (rect.width + 4) + 'px'; marker.style.height = rect.height + 'px';
        marker.style.transform = 'translate(' + (rect.left - body.left - 2) + 'px,' + (rect.top - body.top) + 'px)';
        marker.style.opacity = 1;
        if (jump && !window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
            marker.getAnimations().forEach(function(animation) { animation.cancel(); });
            marker.animate([{opacity: 0.25, scale: '0.96'}, {opacity: 1, scale: '1'}], {duration: 170, easing: 'cubic-bezier(.22,1.25,.36,1)'});
        }
        // "Back to current" is only for the case where the reader has scrolled away
        // from the spoken line, so follow state mirrors whether that line is on screen.
        if (window.__ttsSpeechMode) {
            window.ttsSetFollowing(rect.bottom > 0 && rect.top < window.innerHeight);
        }
        // Fixed reading band: toggling the chrome must never re-scroll the text.
        var topInset = 156;
        var bottomInset = window.__ttsSpeechMode ? 190 : 120;
        if (window.__ttsFollowing && (rect.top < topInset || rect.bottom > window.innerHeight - bottomInset)) {
            var reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
            window.scrollBy({top: rect.top - Math.max(topInset, (window.innerHeight - bottomInset) * 0.42), behavior: reduceMotion ? 'instant' : 'smooth'});
        }
    };
    window.resumeTTSFollow = function() {
        window.ttsSetFollowing(true);
        if (window.__ttsWord) window.setTTSActiveWord(window.__ttsWord);
    };
    window.ttsPositionAt = function(x, y) {
        var range = document.caretRangeFromPoint ? document.caretRangeFromPoint(x, y) : null;
        if (!range && document.caretPositionFromPoint) {
            var caret = document.caretPositionFromPoint(x, y);
            if (caret) { range = document.createRange(); range.setStart(caret.offsetNode, caret.offset); }
        }
        if (!range) return null;
        var element = range.startContainer.nodeType === 1 ? range.startContainer : range.startContainer.parentElement;
        var paragraph = element.closest('[data-tts-index]');
        if (!paragraph) return null;
        var mapped = window.ttsTextMap(paragraph);
        var offset = mapped.map.findIndex(function(item) { return item.node === range.startContainer && item.offset >= range.startOffset; });
        if (offset < 0) offset = mapped.map.length - 1;
        var segments = new Intl.Segmenter('en', {granularity: 'word'}).segment(mapped.text);
        for (var segment of segments) {
            if (segment.isWordLike && segment.index <= offset && offset < segment.index + segment.segment.length) {
                return {paragraphIndex: Number(paragraph.getAttribute('data-tts-index')), offset: segment.index};
            }
        }
        return null;
    };
    window.addEventListener('dblclick', function(event) {
        if (!window.__ttsSpeechMode || event.target.closest('a,button')) return;
        event.preventDefault(); clearTimeout(window.__ttsSingleTap);
        var position = window.ttsPositionAt(event.clientX, event.clientY);
        if (position && position.paragraphIndex >= 0) {
            window.getSelection().removeAllRanges();
            window.webkit.messageHandlers.ttsWordTap.postMessage(position);
        }
    });
    document.addEventListener('contextmenu', function(event) {
        if (!window.__ttsSpeechMode) return;
        // Keep native long-press selection; following remains suspended until explicitly resumed.
        window.ttsSetFollowing(false);
    });
        // Gestures management using PointerEvents
        var startX = 0;
        var startY = 0;
        var startTime = 0;

        window.addEventListener("pointerdown", function(e) {
            if (!e.isPrimary) return;
            if (e.target.tagName === 'A' || e.target.closest('a') || e.target.tagName === 'BUTTON') return;

            startX = e.clientX;
            startY = e.clientY;
            startTime = Date.now();
        });

        window.addEventListener("pointerup", function(e) {
            if (!e.isPrimary) return;
            if (e.target.tagName === 'A' || e.target.closest('a') || e.target.tagName === 'BUTTON') return;

            var diffX = e.clientX - startX;
            var diffY = e.clientY - startY;
            var elapsed = Date.now() - startTime;

            // Check if there is native selection (comments keep it).
            var selection = window.getSelection().toString();
            if (selection && selection.trim().length > 0) {
                return;
            }

            // Tap detection
            if (Math.abs(diffX) < 8 && Math.abs(diffY) < 8 && elapsed < 300) {
                clearTimeout(window.__ttsSingleTap);
                window.__ttsSingleTap = setTimeout(function() {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.toggleControls) {
                        window.webkit.messageHandlers.toggleControls.postMessage("");
                    }
                }, window.__ttsSpeechMode ? 320 : 0);
            }
        });

    """#
}
