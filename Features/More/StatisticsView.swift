// StatisticsView.swift
// Library and reading activity metrics using muted pastel color schemes and systemGray6 containers.

import Charts
import SwiftData
import SwiftUI

// MARK: - Muted Pastel Palette
private enum Pastel {
    static let blue = Color(red: 0.62, green: 0.76, blue: 0.88)     // Soft Sky Blue
    static let purple = Color(red: 0.74, green: 0.68, blue: 0.82)   // Soft Lavender
    static let green = Color(red: 0.66, green: 0.82, blue: 0.74)    // Soft Mint Green
    static let orange = Color(red: 0.90, green: 0.76, blue: 0.66)   // Soft Peach/Apricot
    static let teal = Color(red: 0.62, green: 0.78, blue: 0.78)     // Soft Sage/Teal
}

// MARK: - Snapshot and chart value types

/// Everything the statistics screen shows, counted in one background pass.
private struct StatisticsSnapshot: Sendable {
    var libraryCount = 0
    var totalChapters = 0
    var unreadChapters = 0
    var downloadedChapters = 0
    var lastRead: Date?
    /// One entry per history row, reduced to the only thing the charts need.
    var historyDates: [Date] = []
    var categoryCounts: [CategoryCount] = []
    /// Grouped by source *key*; resolved to a display name on the main actor.
    var sourceCounts: [SourceCount] = []
}

private struct DayActivity: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let dayLabel: String
    let count: Int
}

private struct CategoryCount: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let count: Int
}

private struct HourActivity: Identifiable, Sendable {
    let id = UUID()
    let hour: Int
    let hourLabel: String
    let count: Int
}

private struct SourceCount: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let count: Int
}

struct StatisticsView: View {
    @Environment(SourceManager.self) private var sourceManager
    @Environment(\.modelContext) private var modelContext

    /// Everything the screen needs, counted once off the main thread.
    ///
    /// This used to be `@Query private var chapters: [Chapter]`, which pulls
    /// every chapter in the store into memory and re-runs on any write; the
    /// "downloaded" tile then faulted each chapter's `downloadItem`. On a real
    /// library that is tens of thousands of objects to render five numbers.
    @State private var stats = StatisticsSnapshot()

    // Summary calculations
    private var unreadCount: Int { stats.unreadChapters }

    private var downloadedCount: Int { stats.downloadedChapters }

    private var lastReadText: String {
        stats.lastRead?.timeAgo ?? "Never"
    }

    private var columns: [GridItem] {
        [GridItem(.flexible()), GridItem(.flexible())]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Summary Overview Grid (systemGray6 cards, flat pastel icons)
                LazyVGrid(columns: columns, spacing: 16) {
                    summaryCard(title: "Library", value: "\(stats.libraryCount)", icon: "books.vertical.fill", color: Pastel.blue)
                    summaryCard(title: "Chapters Read", value: "\(readChaptersCount)", icon: "checkmark.circle.fill", color: Pastel.green)
                    summaryCard(title: "Downloaded", value: "\(downloadedCount)", icon: "arrow.down.circle.fill", color: Pastel.teal)
                    summaryCard(title: "Last Read", value: lastReadText, icon: "clock.arrow.circlepath", color: Pastel.orange)
                }

                // 1. Weekly Reading Activity Card (muted pastel purple)
                weeklyActivityCard

                // 2. Reading Progress Stacked Card (muted pastel green and purple)
                readingProgressCard

                // 3. Category Breakdown Card (muted pastel orange progress bars)
                categoryBreakdownCard

                // 4. Best Reading Hours Card (muted pastel blue bar chart)
                bestReadingHoursCard

                // 5. Novels by Source Card (muted pastel teal progress rows)
                novelsBySourceCard
            }
            .padding()
        }
        .appNavigationTitle("Statistics")
        .task { await loadStatistics() }
    }

    // MARK: - Snapshot

    private func loadStatistics() async {
        let container = modelContext.container
        let snapshot = await Task.detached(priority: .userInitiated) { () -> StatisticsSnapshot in
            let context = ModelContext(container)
            var snapshot = StatisticsSnapshot()

            snapshot.libraryCount =
                (try? context.fetchCount(FetchDescriptor<Entry>(predicate: #Predicate { $0.inLibrary }))) ?? 0
            snapshot.totalChapters =
                (try? context.fetchCount(FetchDescriptor<Chapter>(predicate: #Predicate { !$0.hidden }))) ?? 0
            snapshot.unreadChapters =
                (try? context.fetchCount(FetchDescriptor<Chapter>(predicate: #Predicate { !$0.hidden && $0.read == false }))) ?? 0
            // Download rows are few (one per downloaded chapter), and a
            // predicate cannot compare an enum case, so count them here.
            let downloads = (try? context.fetch(FetchDescriptor<DownloadItem>())) ?? []
            snapshot.downloadedChapters = downloads.count { $0.state == DownloadState.completed }

            // History rows are needed as dates, not objects, so map them here
            // and let the model objects go.
            let historyDescriptor = FetchDescriptor<History>(
                sortBy: [SortDescriptor(\.lastRead, order: .reverse)]
            )
            let history = (try? context.fetch(historyDescriptor)) ?? []
            snapshot.historyDates = history.map(\.lastRead)
            snapshot.lastRead = history.first?.lastRead

            let entries = (try? context.fetch(
                FetchDescriptor<Entry>(predicate: #Predicate { $0.inLibrary })
            )) ?? []
            var bySource: [String: Int] = [:]
            for entry in entries { bySource[entry.sourceKey, default: 0] += 1 }
            snapshot.sourceCounts = bySource
                .map { SourceCount(name: $0.key, count: $0.value) }
                .sorted { $0.count > $1.count }

            let categories = (try? context.fetch(
                FetchDescriptor<Category>(sortBy: [SortDescriptor(\.order)])
            )) ?? []
            snapshot.categoryCounts = categories
                .map { CategoryCount(name: $0.name, count: $0.entries.count) }
                .sorted { $0.count > $1.count }

            return snapshot
        }.value

        stats = snapshot
    }

    // MARK: - Card Container

    private struct CardContainer<Content: View>: View {
        let content: Content
        
        init(@ViewBuilder content: () -> Content) {
            self.content = content()
        }
        
        var body: some View {
            content
                .padding()
                .background(AppTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.05), radius: 5, x: 0, y: 2)
        }
    }

    // MARK: - Summary Card Helper

    private func summaryCard(title: String, value: String, icon: String, color: Color) -> some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 8) {
                AppIcon(systemName: icon, size: 17, relativeTo: .headline)
                    .font(.headline)
                    .foregroundStyle(color)

                Text(value)
                    .font(Typography.title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(.primary)

                Text(title)
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Data Models
    // The value types live at file scope so the snapshot can hold them.

    // MARK: - 1. Weekly Reading Activity

    private var weeklyActivityData: [DayActivity] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        var dayCounts: [Date: Int] = [:]
        for date in stats.historyDates {
            let dayStart = calendar.startOfDay(for: date)
            dayCounts[dayStart, default: 0] += 1
        }

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "E"

        var data: [DayActivity] = []
        for offset in (0..<7).reversed() {
            if let date = calendar.date(byAdding: .day, value: -offset, to: today) {
                let label = dayFormatter.string(from: date)
                let count = dayCounts[date] ?? 0
                data.append(DayActivity(date: date, dayLabel: label, count: count))
            }
        }
        return data
    }

    private var weeklyActivityCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    AppIcon(systemName: "chart.bar.fill", size: 17, relativeTo: .headline)
                        .foregroundStyle(Pastel.purple)
                    Text("Weekly Activity")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                }
                
                Text("Chapters read per day in the last 7 days")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                
                let activity = weeklyActivityData
                if activity.map(\.count).reduce(0, +) > 0 {
                    Chart(activity) { day in
                        BarMark(
                            x: .value("Day", day.dayLabel),
                            y: .value("Chapters", day.count)
                        )
                        .foregroundStyle(Pastel.purple)
                        .cornerRadius(4)
                    }
                    .frame(height: 120)
                    .chartYAxis {
                        AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                                .foregroundStyle(AppTheme.hairline)
                            AxisValueLabel()
                                .foregroundStyle(.secondary)
                                .font(.caption2)
                        }
                    }
                    .chartXAxis {
                        AxisMarks { _ in
                            AxisValueLabel()
                                .foregroundStyle(.secondary)
                                .font(.caption2)
                        }
                    }
                } else {
                    noDataView(message: "No reading activity recorded recently")
                }
            }
        }
    }

    // MARK: - 2. Reading Progress (Stacked Bar)

    private var totalChaptersCount: Int {
        max(stats.totalChapters, 0)
    }

    private var readChaptersCount: Int {
        max(totalChaptersCount - unreadCount, 0)
    }

    private var readingProgressCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    AppIcon(systemName: "percent", size: 17, relativeTo: .headline)
                        .foregroundStyle(Pastel.green)
                    Text("Reading Progress")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                }
                
                Text("Split of read vs unread chapters across library")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                
                if totalChaptersCount > 0 {
                    VStack(spacing: 12) {
                        Chart {
                            BarMark(
                                x: .value("Chapters", readChaptersCount)
                            )
                            .foregroundStyle(Pastel.green)
                            .cornerRadius(4)
                            
                            BarMark(
                                x: .value("Chapters", unreadCount),
                                stacking: .standard
                            )
                            .foregroundStyle(Pastel.purple)
                            .cornerRadius(4)
                        }
                        .frame(height: 28)
                        .chartXAxis(.hidden)
                        .chartYAxis(.hidden)
                        
                        HStack(spacing: 20) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Pastel.green)
                                    .frame(width: 10, height: 10)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Read")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text("\(readChaptersCount) (\(Int(Double(readChaptersCount) / Double(totalChaptersCount) * 100))%)")
                                        .font(Typography.caption)
                                        .bold()
                                        .foregroundStyle(.primary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Pastel.purple)
                                    .frame(width: 10, height: 10)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Unread")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text("\(unreadCount) (\(Int(Double(unreadCount) / Double(totalChaptersCount) * 100))%)")
                                        .font(Typography.caption)
                                        .bold()
                                        .foregroundStyle(.primary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } else {
                    noDataView(message: "No chapters loaded in library")
                }
            }
        }
    }

    // MARK: - 3. Category Breakdown

    private var categoryData: [CategoryCount] {
        stats.categoryCounts
            .prefix(5)
            .map { $0 }
    }

    private var maxCategoryNovelCount: Int {
        categoryData.map(\.count).max() ?? 1
    }

    private var categoryBreakdownCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    AppIcon(systemName: "square.grid.2x2.fill", size: 17, relativeTo: .headline)
                        .foregroundStyle(Pastel.orange)
                    Text("Category Breakdown")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                }
                
                Text("Distribution of library entries across categories (top 5)")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                
                let categoriesList = categoryData
                if !categoriesList.isEmpty {
                    VStack(spacing: 12) {
                        ForEach(categoriesList) { item in
                            HStack(spacing: 12) {
                                Text(item.name)
                                    .font(Typography.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 90, alignment: .leading)
                                    .lineLimit(1)
                                
                                GeometryReader { geometry in
                                    ZStack(alignment: .leading) {
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(.quaternary)
                                            .frame(height: 10)
                                        
                                        let maxVal = maxCategoryNovelCount
                                        let progress = maxVal > 0 ? CGFloat(item.count) / CGFloat(maxVal) : 0
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(Pastel.orange)
                                            .frame(width: geometry.size.width * progress, height: 10)
                                    }
                                }
                                .frame(height: 10)
                                
                                Text("\(item.count)")
                                    .font(Typography.caption)
                                    .bold()
                                    .foregroundStyle(Pastel.orange)
                                    .frame(width: 30, alignment: .trailing)
                            }
                        }
                    }
                } else {
                    noDataView(message: "No categories defined")
                }
            }
        }
    }

    // MARK: - 4. Best Reading Hours

    private var hourlyActivityData: [HourActivity] {
        var hourCounts: [Int: Int] = [:]
        let calendar = Calendar.current
        for date in stats.historyDates {
            hourCounts[calendar.component(.hour, from: date), default: 0] += 1
        }
        
        return (0..<24).map { hour in
            let label: String
            if hour == 0 {
                label = "12am"
            } else if hour < 12 {
                label = "\(hour)am"
            } else if hour == 12 {
                label = "12pm"
            } else {
                label = "\(hour - 12)pm"
            }
            return HourActivity(hour: hour, hourLabel: label, count: hourCounts[hour] ?? 0)
        }
    }

    private var peakReadingHour: String {
        let data = hourlyActivityData
        if let peak = data.max(by: { $0.count < $1.count }), peak.count > 0 {
            return peak.hourLabel
        }
        return "None"
    }

    private var bestReadingHoursCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    AppIcon(systemName: "clock.fill", size: 17, relativeTo: .headline)
                        .foregroundStyle(Pastel.blue)
                    Text("Reading Hours")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                }
                
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(peakReadingHour)
                        .font(.title2)
                        .bold()
                        .foregroundStyle(Pastel.blue)
                    Text("peak reading time")
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 4)
                
                let hourlyData = hourlyActivityData
                if hourlyData.map(\.count).reduce(0, +) > 0 {
                    Chart(hourlyData, id: \.hour) { data in
                        BarMark(
                            x: .value("Hour", data.hour),
                            y: .value("Count", data.count)
                        )
                        .foregroundStyle(
                            data.hourLabel == peakReadingHour ? Pastel.blue : Pastel.blue.opacity(0.4)
                        )
                        .cornerRadius(2)
                    }
                    .frame(height: 80)
                    .chartXAxis {
                        AxisMarks(values: [0, 6, 12, 18]) { value in
                            AxisValueLabel {
                                if let hour = value.as(Int.self) {
                                    let label = hour == 0 ? "12am" : (hour < 12 ? "\(hour)am" : (hour == 12 ? "12pm" : "\(hour-12)pm"))
                                    Text(label)
                                        .font(.caption2)
                                }
                            }
                        }
                    }
                    .chartYAxis(.hidden)
                } else {
                    noDataView(message: "No hourly reading data available")
                }
            }
        }
    }

    // MARK: - 5. Books by Source

    private func sourceName(for key: String) -> String {
        sourceManager.source(forKey: key)?.name ?? SourceKey.identifier(from: key)
    }

    private var sourceCountData: [SourceCount] {
        stats.sourceCounts
            .map { SourceCount(name: sourceName(for: $0.name), count: $0.count) }
            .prefix(5)
            .map { $0 }
    }

    private var maxSourceNovelCount: Int {
        sourceCountData.map(\.count).max() ?? 1
    }

    private var novelsBySourceCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    AppIcon(systemName: "globe", size: 17, relativeTo: .headline)
                        .foregroundStyle(Pastel.teal)
                    Text("Books by Source")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                }
                
                Text("Distribution of library entries by source")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                
                let sourceList = sourceCountData
                if !sourceList.isEmpty {
                    VStack(spacing: 12) {
                        ForEach(sourceList) { item in
                            HStack(spacing: 12) {
                                Text(item.name)
                                    .font(Typography.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 100, alignment: .leading)
                                    .lineLimit(1)
                                
                                GeometryReader { geometry in
                                    ZStack(alignment: .leading) {
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(.quaternary)
                                            .frame(height: 10)
                                        
                                        let maxVal = maxSourceNovelCount
                                        let progress = maxVal > 0 ? CGFloat(item.count) / CGFloat(maxVal) : 0
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(Pastel.teal)
                                            .frame(width: geometry.size.width * progress, height: 10)
                                    }
                                }
                                .frame(height: 10)
                                
                                Text("\(item.count)")
                                    .font(Typography.caption)
                                    .bold()
                                    .foregroundStyle(Pastel.teal)
                                    .frame(width: 30, alignment: .trailing)
                            }
                        }
                    }
                } else {
                    noDataView(message: "No novels added to library")
                }
            }
        }
    }

    // MARK: - No Data View Helper

    private func noDataView(message: String) -> some View {
        VStack(spacing: 8) {
            AppIcon(systemName: "chart.pie", size: 13, relativeTo: .footnote)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(message)
                .font(Typography.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 100)
    }
}
