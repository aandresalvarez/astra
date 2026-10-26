import SwiftUI

struct ConfigureCardIcon: View {
    let systemName: String
    let color: Color
    var brand: BrandMark? = nil

    var body: some View {
        CapabilityLeadingIcon(systemImage: systemName, brand: brand, pointSize: 14)
            .foregroundStyle(color)
            .frame(width: 28, height: 28)
            .background(color.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

struct ConfigureCardChip: View {
    let title: String
    var color: Color? = nil

    var body: some View {
        Text(title)
            .font(Stanford.caption(10))
            .foregroundStyle(color ?? Stanford.coolGrey)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((color ?? Color.primary).opacity(color == nil ? 0.04 : 0.1))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

struct ConfigureSelectionList<Content: View>: View {
    let maxContentWidth: CGFloat
    @ViewBuilder let content: Content

    init(maxContentWidth: CGFloat = 640, @ViewBuilder content: () -> Content) {
        self.maxContentWidth = maxContentWidth
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .padding(16)
            .frame(maxWidth: maxContentWidth, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct ConfigureSelectionSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    private let columns = [
        GridItem(.adaptive(minimum: 330, maximum: 460), spacing: 12, alignment: .top)
    ]

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(Stanford.caption(10).weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ConfigureSelectionCard<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)

        HStack(spacing: 12) {
            content
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(Color.primary.opacity(0.018)))
        .overlay {
            shape.stroke(Stanford.borderSubtle, lineWidth: 1)
        }
        .clipShape(shape)
    }
}
