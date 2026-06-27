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
