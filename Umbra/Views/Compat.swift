import SwiftUI

extension View {
    /// `onChange` for iOS 16 that uses the newer form where available (the old one is deprecated there).
    @ViewBuilder
    func onChangeOf<V: Equatable>(_ value: V, perform action: @escaping (V) -> Void) -> some View {
        if #available(iOS 17, macOS 14, visionOS 1, *) {
            onChange(of: value) { _, new in action(new) }
        } else {
            onChange(of: value, perform: action)
        }
    }
}
