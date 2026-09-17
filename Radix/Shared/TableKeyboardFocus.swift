import SwiftUI

extension View {
    func tableKeyboardFocus<Value: Hashable>(
        _ binding: FocusState<Value>.Binding,
        equals value: Value
    ) -> some View {
        focused(binding, equals: value)
            // On macOS 27, clicking a table row can leave keyboard focus in the previous view.
            .simultaneousGesture(TapGesture().onEnded {
                binding.wrappedValue = value
            })
    }
}
