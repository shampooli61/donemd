import SwiftUI
import UIKit

/// UITextField exposes markedTextRange so search never issues queries from a
/// half-composed IME candidate. UIKit continues owning focus and composition.
struct MobileEditorSearchField: UIViewRepresentable {
    @Binding var text: String
    @Binding var composing: Bool
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = "查找内容"
        field.accessibilityLabel = "查找内容"
        field.accessibilityIdentifier = "native-search-query"
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.returnKeyType = .search
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.text = text
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        // Never assign text during composition or while the user is editing.
        // This avoids selection/candidate truncation from a SwiftUI refresh.
        if !field.isFirstResponder, field.markedTextRange == nil, field.text != text {
            field.text = text
        }
    }
    static func dismantleUIView(_ field: UITextField, coordinator: Coordinator) {
        field.delegate = nil
        field.removeTarget(coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
    }
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: MobileEditorSearchField
        init(_ parent: MobileEditorSearchField) { self.parent = parent }
        @objc func changed(_ field: UITextField) {
            let marked = field.markedTextRange != nil
            let current = field.text ?? ""
            if parent.composing != marked { parent.composing = marked }
            if parent.text != current { parent.text = current }
        }
        func textFieldDidChangeSelection(_ field: UITextField) { changed(field) }
        func textFieldDidEndEditing(_ field: UITextField) { changed(field) }
        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            guard field.markedTextRange == nil else { return true }
            changed(field)
            parent.onSubmit()
            return false
        }
    }
}
