import SwiftUI

struct ShiftDisplayModePicker: View {
    @Binding var selection: ShiftDisplayMode
    let selectedSymbolColor: Color
    @Namespace private var selectionNamespace
    @State private var visualSelection: ShiftDisplayMode?
    private let selectionAnimationDuration = 0.28

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ShiftDisplayMode.allCases) { mode in
                let isSelected = isVisuallySelected(mode)

                Button {
                    select(mode)
                } label: {
                    modeButtonLabel(for: mode, isSelected: isSelected)
                }
                .buttonStyle(.plain)
                .help(mode.title)
                .accessibilityLabel(mode.title)
                .accessibilityAddTraits(selection == mode ? .isSelected : [])
            }
        }
#if os(iOS)
        .frame(height: 33)
        .background(Color(uiColor: .secondarySystemFill), in: Capsule())
#else
        .frame(height: 25)
        .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
#endif
        .fixedSize(horizontal: true, vertical: false)
        .onAppear {
            visualSelection = selection
        }
        .onChange(of: selection) { _, newValue in
            guard visualSelection != newValue else { return }
            withAnimation(.snappy(duration: selectionAnimationDuration)) {
                visualSelection = newValue
            }
        }
    }

    private func select(_ mode: ShiftDisplayMode) {
        guard mode != selection else { return }
        withAnimation(.snappy(duration: selectionAnimationDuration)) {
            visualSelection = mode
        }
        selection = mode
    }

    private func isVisuallySelected(_ mode: ShiftDisplayMode) -> Bool {
        (visualSelection ?? selection) == mode
    }

    private func modeButtonLabel(
        for mode: ShiftDisplayMode,
        isSelected: Bool
    ) -> some View {
        Image(systemName: mode.systemImage)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(isSelected ? selectedSymbolColor : .secondary)
#if os(iOS)
            .frame(minWidth: 44, maxHeight: .infinity)
#else
            .frame(width: 36, height: 25)
#endif
            .contentShape(Rectangle())
            .background {
                selectionBackground(isSelected: isSelected)
            }
    }

    @ViewBuilder
    private func selectionBackground(isSelected: Bool) -> some View {
        if isSelected {
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.3))
                .padding(3)
                .matchedGeometryEffect(
                    id: "shift-display-mode-selection",
                    in: selectionNamespace
                )
        }
    }
}
