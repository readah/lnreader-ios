// CategoryTabView.swift
// Horizontal scrolling category filter pills with Liquid Glass styling.

import SwiftData
import SwiftUI

struct CategoryTabView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.noLiquidGlass) private var classic
    let categories: [Category]
    @Binding var selectedCategory: Category?
    var isUpdating = false
    var onUpdate: (Category) -> Void = { _ in }
    var onToggleUpdates: (Category) -> Void = { _ in }
    @Namespace private var namespace
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            AppGlassEffectContainer(spacing: 8) {
              // Without a stack the container lays its pills out vertically.
              HStack(spacing: 8) {
                categoryPill(
                    title: "All",
                    isSelected: selectedCategory == nil
                ) {
                    selectedCategory = nil
                }
                .glassEffectID("all", in: namespace)

                ForEach(categories) { category in
                    categoryPill(
                        title: category.name,
                        isSelected: selectedCategory?.id == category.id,
                        isExcluded: CategoryFlags.isExcluded(category.flags)
                    ) {
                        selectedCategory = category
                    }
                    .appContextMenu { actionsMenu(for: category) }
                    .glassEffectID(category.id, in: namespace)
                }
              }
              .padding(.horizontal)
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func actionsMenu(for category: Category) -> some View {
        let excluded = CategoryFlags.isExcluded(category.flags)
        Button("Update this category", systemImage: "arrow.clockwise") { onUpdate(category) }
            .disabled(isUpdating)
        Button(
            excluded ? "Include in library updates" : "Exclude from library updates",
            systemImage: excluded ? "arrow.triangle.2.circlepath" : "pause.circle"
        ) { onToggleUpdates(category) }
    }

    @ViewBuilder
    private func categoryPill(
        title: String,
        isSelected: Bool,
        isExcluded: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            withAnimation(AppMotion.tabSwitch(reduceMotion: reduceMotion)) { action() }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                if isExcluded {
                    AppIcon(systemName: "pause.circle", size: 13, relativeTo: .footnote)
                        .accessibilityLabel("Excluded from updates")
                }
            }
                .font(Typography.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        // A tinted glass pill reads as selected in any colour scheme; weight and
        // colour alone were too subtle against the other pills.
        .appGlassEffect(
            isSelected ? .regular.tint(Color.primary.opacity(0.28)).interactive() : .regular.interactive(),
            in: .capsule,
            frostTint: !classic && isSelected ? Color.primary.opacity(0.14) : nil)
        .contentShape(.capsule)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
