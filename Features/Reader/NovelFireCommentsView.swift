import SwiftUI

struct NovelFireCommentsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let postId: String
    let chapterId: String
    let csrfToken: String
    let chapterPath: String
    let backgroundColorHex: String
    let textColorHex: String
    let site: CommentSite
    private let initialHTML: String

    @State private var comments: [NativeChapterComment] = []
    @State private var nextCursor: String?
    @State private var hasMoreComments: Bool
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showLoginSheet = false
    @State private var hideSpoilers = false
    @State private var onlyReplies = false
    @State private var activeVotes = Set<String>()
    @State private var resolvedPostId = ""
    @State private var resolvedChapterId = ""
    @State private var resolvedCSRF = ""
    @State private var pendingVote: (String, Bool)?

    init(postId: String, chapterId: String, csrfToken: String, initialCommentsHtml: String,
         initialNextCursor: String?, initialHasMore: Bool, chapterPath: String,
         backgroundColorHex: String, textColorHex: String, site: CommentSite = .novelFire) {
        self.postId = postId; self.chapterId = chapterId; self.csrfToken = csrfToken
        self.initialHTML = initialCommentsHtml; self.chapterPath = chapterPath
        self.backgroundColorHex = backgroundColorHex; self.textColorHex = textColorHex; self.site = site
        self._nextCursor = State(initialValue: initialNextCursor)
        self._hasMoreComments = State(initialValue: initialHasMore)
    }

    private var visibleComments: [NativeChapterComment] {
        comments.filter { (!hideSpoilers || !$0.isSpoiler) && (!onlyReplies || !$0.replies.isEmpty) }
    }

    var body: some View {
        NavigationStack {
            List {
                if comments.isEmpty && isLoading {
                    ProgressView("Loading comments…").frame(maxWidth: .infinity).listRowBackground(Color.clear)
                } else if visibleComments.isEmpty && errorMessage == nil {
                    ContentUnavailableView(onlyReplies || hideSpoilers ? "No matching comments" : "No comments yet",
                                           systemImage: "bubble.left.and.bubble.right",
                                           description: Text(onlyReplies || hideSpoilers ? "Change the filters or load more comments." : "This chapter has no comments yet."))
                        .listRowBackground(Color.clear)
                }
                if let errorMessage {
                    ContentUnavailableView {
                        AppLabel("Couldn't load comments", systemName: "exclamationmark.circle", size: 17, relativeTo: .body)
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Try again") { Task { await loadFirstPage() } }
                    }
                    .listRowBackground(Color.clear)
                }
                ForEach(visibleComments) { comment in
                    NativeCommentThread(comment: comment, activeVotes: activeVotes, hideSpoilers: hideSpoilers, onVote: vote)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color(hex: backgroundColorHex) ?? Color(.secondarySystemGroupedBackground))
                }
                if hasMoreComments {
                    Button { Task { await loadMore() } } label: {
                        Group {
                            if isLoading { ProgressView() } else { AppLabel("More comments", systemName: "arrow.down.circle", size: 17, relativeTo: .body) }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(isLoading)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(backgroundColorHex.isEmpty ? .visible : .hidden)
            .background(Color(hex: backgroundColorHex) ?? Color(.systemGroupedBackground))
            .foregroundStyle(Color(hex: textColorHex) ?? .primary)
            .navigationTitle("Comments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done", role: .close) { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Toggle("Hide spoilers", isOn: $hideSpoilers)
                        Toggle("With replies", isOn: $onlyReplies)
                        Divider()
                        Button { showLoginSheet = true } label: { AppLabel("Sign in to \(site.displayName)", systemName: "person.crop.circle", size: 17, relativeTo: .body) }
                    } label: {
                        AppLabel("Comment filters and account", systemName: hideSpoilers || onlyReplies ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease", size: 17, relativeTo: .body)
                    }
                }
            }
            .animation(AppMotion.gentle(reduceMotion: reduceMotion), value: hideSpoilers)
            .animation(AppMotion.gentle(reduceMotion: reduceMotion), value: onlyReplies)
            .refreshable { await loadFirstPage() }
            .task {
                resolvedPostId = postId; resolvedChapterId = chapterId; resolvedCSRF = csrfToken
                if !initialHTML.isEmpty {
                    do { comments = try await parse(initialHTML) } catch { errorMessage = error.localizedDescription }
                } else { await loadFirstPage() }
            }
            .sheet(isPresented: $showLoginSheet, onDismiss: { pendingVote = nil }) {
                NovelFireLoginView(onLoginSuccess: {
                    let action = pendingVote
                    pendingVote = nil
                    Task {
                        await loadFirstPage()
                        if let action { vote(action.0, action.1) }
                    }
                }, site: site)
            }
        }
    }

    private func parse(_ html: String) async throws -> [NativeChapterComment] {
        try await Task.detached(priority: .userInitiated) { try NovelFireCommentsService.nativeComments(from: html) }.value
    }

    @MainActor private func loadFirstPage() async {
        guard !isLoading else { return }
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let metadata = try await NovelFireCommentsService.shared.fetchChapterMetadata(chapterPath: chapterPath, site: site, forceRefresh: true)
            try Task.checkCancellation()
            resolvedPostId = metadata.postId; resolvedChapterId = metadata.chapterId; resolvedCSRF = metadata.csrfToken
            let page = try await NovelFireCommentsService.shared.fetchComments(postId: metadata.postId, chapterId: metadata.chapterId, site: site)
            let parsed = try await parse(page.html)
            try Task.checkCancellation()
            comments = parsed; nextCursor = page.next_cursor; hasMoreComments = page.has_more_pages
        } catch is CancellationError { }
          catch { errorMessage = error.localizedDescription }
    }

    @MainActor private func loadMore() async {
        guard !isLoading, let cursor = nextCursor else { return }
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let page = try await NovelFireCommentsService.shared.fetchComments(postId: resolvedPostId, chapterId: resolvedChapterId, cursor: cursor, site: site)
            let parsed = try await parse(page.html)
            try Task.checkCancellation()
            let known = Set(comments.map(\.id))
            comments.append(contentsOf: parsed.filter { !known.contains($0.id) })
            nextCursor = page.next_cursor; hasMoreComments = page.has_more_pages && page.next_cursor != cursor
        } catch is CancellationError { }
          catch { errorMessage = error.localizedDescription }
    }

    private func vote(_ id: String, _ isLike: Bool) {
        guard !activeVotes.contains(id) else { return }
        guard NovelFireCommentsService.shared.hasSession(for: site) else {
            pendingVote = (id, isLike); showLoginSheet = true; return
        }
        activeVotes.insert(id)
        Task { @MainActor in
            defer { activeVotes.remove(id) }
            do {
                let service = NovelFireCommentsService.shared
                if resolvedCSRF.isEmpty { resolvedCSRF = try await service.refreshCsrfToken(chapterPath: chapterPath, site: site) }
                func send() async throws -> NovelFireCommentsService.ActionResponse {
                    if isLike { return try await service.likeComment(commentId: id, csrfToken: resolvedCSRF, referer: site.referer(chapterPath: chapterPath), site: site) }
                    return try await service.dislikeComment(commentId: id, csrfToken: resolvedCSRF, referer: site.referer(chapterPath: chapterPath), site: site)
                }
                let response: NovelFireCommentsService.ActionResponse
                do { response = try await send() } catch where (error as NSError).code == 419 {
                    resolvedCSRF = try await service.refreshCsrfToken(chapterPath: chapterPath, site: site)
                    response = try await send()
                }
                comments = updatingVote(comments, id: id, likes: response.likes, dislikes: response.dislikes)
            } catch {
                if [401, 403].contains((error as NSError).code) {
                    UserDefaults.standard.set(false, forKey: "comments.authenticated." + site.rawValue)
                    pendingVote = (id, isLike); showLoginSheet = true
                } else { errorMessage = error.localizedDescription }
            }
        }
    }

    private func updatingVote(_ rows: [NativeChapterComment], id: String, likes: Int, dislikes: Int) -> [NativeChapterComment] {
        rows.map { item in
            var row = item
            if row.id == id { row.likes = likes; row.dislikes = dislikes }
            row.replies = updatingVote(row.replies, id: id, likes: likes, dislikes: dislikes)
            return row
        }
    }
}

private struct NativeCommentThread: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let comment: NativeChapterComment
    let activeVotes: Set<String>
    let hideSpoilers: Bool
    let onVote: (String, Bool) -> Void
    @State private var expanded = false
    @State private var revealed = Set<String>()

    private struct Reply: Identifiable {
        let comment: NativeChapterComment
        let depth: Int
        var id: String { comment.id }
    }
    private var replies: [Reply] {
        func flatten(_ rows: [NativeChapterComment], depth: Int) -> [Reply] {
            rows.flatMap { row -> [Reply] in
                guard !hideSpoilers || !row.isSpoiler else { return [] }
                return [Reply(comment: row, depth: depth)] + flatten(row.replies, depth: depth + 1)
            }
        }
        return flatten(comment.replies, depth: 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            cell(comment)
            if !replies.isEmpty {
                Button {
                    withAnimation(AppMotion.gentle(reduceMotion: reduceMotion)) { expanded.toggle() }
                } label: {
                    AppLabel(expanded ? "Hide replies" : "\(replies.count) replies", systemName: expanded ? "chevron.up" : "bubble.left.and.bubble.right", size: 15, relativeTo: .subheadline)
                        .font(.subheadline.weight(.medium))
                }.buttonStyle(.borderless)
                if expanded {
                    ForEach(replies) { reply in
                        cell(reply.comment)
                            .padding(.leading, CGFloat(min(reply.depth, 3)) * 12)
                            .transition(.opacity)
                    }
                }
            }
        }.padding(.vertical, 6)
    }

    private func cell(_ item: NativeChapterComment) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Text(String(item.author.prefix(1)).uppercased())
                    .font(.caption.bold()).frame(width: 28, height: 28)
                    .background(.quaternary, in: .circle)
                    .accessibilityHidden(true)
                Text(item.author).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                if !item.date.isEmpty { Text(item.date).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            if item.isSpoiler && !revealed.contains(item.id) {
                Button("Show spoiler", systemImage: "eye.slash") {
                    withAnimation(AppMotion.gentle(reduceMotion: reduceMotion)) { _ = revealed.insert(item.id) }
                }.buttonStyle(.borderless)
            } else {
                Text(item.text).font(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 20) {
                Button { onVote(item.id, true) } label: { AppLabel("\(item.likes)", systemName: "hand.thumbsup", size: 17, relativeTo: .body) }
                    .accessibilityLabel("Like comment by \(item.author), \(item.likes) likes")
                Button { onVote(item.id, false) } label: { AppLabel("\(item.dislikes)", systemName: "hand.thumbsdown", size: 12, relativeTo: .caption) }
                    .accessibilityLabel("Dislike comment by \(item.author), \(item.dislikes) dislikes")
                if activeVotes.contains(item.id) { ProgressView().controlSize(.mini) }
            }
            .font(.caption).foregroundStyle(.secondary).buttonStyle(.borderless)
            .disabled(activeVotes.contains(item.id))
        }
    }
}
