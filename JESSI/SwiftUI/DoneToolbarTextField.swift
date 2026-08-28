import SwiftUI
import UIKit

// so bascially without this theres no way to close the numpad :troll:

struct DoneToolbarTextField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var keyboardType: UIKeyboardType = .default
    var textAlignment: NSTextAlignment = .right
    var font: UIFont = .systemFont(ofSize: 16)
    var onEndEditing: (() -> Void)? = nil
    // When set, Return triggers this (keyboard stays up) instead of dismissing.
    var onSubmit: (() -> Void)? = nil
    var returnKeyType: UIReturnKeyType = .done

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: DoneToolbarTextField

        init(parent: DoneToolbarTextField) {
            self.parent = parent
        }

        @objc func textChanged(_ sender: UITextField) {
            parent.text = sender.text ?? ""
        }

        @objc func doneTapped(_ sender: UIBarButtonItem) {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            if let onSubmit = parent.onSubmit {
                DispatchQueue.main.async {
                    onSubmit()
                }
                return true
            }
            textField.resignFirstResponder()
            return true
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            parent.onEndEditing?()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField(frame: .zero)
        tf.borderStyle = .none
        tf.backgroundColor = .clear
        tf.clipsToBounds = true
        tf.textColor = UIColor.label
        tf.font = font
        tf.keyboardType = keyboardType
        tf.autocapitalizationType = .none
        tf.autocorrectionType = .no
        tf.placeholder = placeholder
        tf.textAlignment = textAlignment
        tf.returnKeyType = returnKeyType
        tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tf.delegate = context.coordinator
        tf.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)

        let toolbar = UIToolbar()
        toolbar.sizeToFit()
        let flex = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        let done = UIBarButtonItem(title: "Done", style: .done, target: context.coordinator, action: #selector(Coordinator.doneTapped(_:)))
        done.tintColor = .systemGreen
        toolbar.items = [flex, done]
        tf.inputAccessoryView = toolbar

        return tf
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
        if uiView.placeholder != placeholder {
            uiView.placeholder = placeholder
        }
        if uiView.keyboardType != keyboardType {
            uiView.keyboardType = keyboardType
        }
        if uiView.textAlignment != textAlignment {
            uiView.textAlignment = textAlignment
        }
        if uiView.font != font {
            uiView.font = font
        }
        if uiView.returnKeyType != returnKeyType {
            uiView.returnKeyType = returnKeyType
        }
    }
}

struct FocusableDoneToolbarTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFirstResponder: Bool
    var placeholder: String = ""
    var keyboardType: UIKeyboardType = .default
    var textAlignment: NSTextAlignment = .right
    var font: UIFont = .systemFont(ofSize: 16)
    var onEndEditing: (() -> Void)? = nil

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: FocusableDoneToolbarTextField

        init(parent: FocusableDoneToolbarTextField) {
            self.parent = parent
        }

        @objc func textChanged(_ sender: UITextField) {
            parent.text = sender.text ?? ""
        }

        @objc func doneTapped(_ sender: UIBarButtonItem) {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            if !parent.isFirstResponder {
                parent.isFirstResponder = true
            }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return true
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            if parent.isFirstResponder {
                parent.isFirstResponder = false
            }
            parent.onEndEditing?()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField(frame: .zero)
        tf.borderStyle = .none
        tf.backgroundColor = .clear
        tf.clipsToBounds = true
        tf.textColor = UIColor.label
        tf.font = font
        tf.keyboardType = keyboardType
        tf.autocapitalizationType = .none
        tf.autocorrectionType = .no
        tf.placeholder = placeholder
        tf.textAlignment = textAlignment
        tf.returnKeyType = .done
        tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tf.delegate = context.coordinator
        tf.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)

        let toolbar = UIToolbar()
        toolbar.sizeToFit()
        let flex = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        let done = UIBarButtonItem(title: "Done", style: .done, target: context.coordinator, action: #selector(Coordinator.doneTapped(_:)))
        done.tintColor = .systemGreen
        toolbar.items = [flex, done]
        tf.inputAccessoryView = toolbar

        return tf
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
        if uiView.placeholder != placeholder {
            uiView.placeholder = placeholder
        }
        if uiView.keyboardType != keyboardType {
            uiView.keyboardType = keyboardType
        }
        if uiView.textAlignment != textAlignment {
            uiView.textAlignment = textAlignment
        }
        if uiView.font != font {
            uiView.font = font
        }

        if isFirstResponder {
            if !uiView.isFirstResponder {
                uiView.becomeFirstResponder()
            }
        } else {
            if uiView.isFirstResponder {
                uiView.resignFirstResponder()
            }
        }
    }
}
