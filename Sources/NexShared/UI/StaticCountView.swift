import AppKit

final class StaticCountView: NSView {
    private let label = NSTextField(labelWithString: "\(L10n.text(zhHans: "字数", en: "Words")) 0")
    private var recognitionKind: RecognitionSlotKind = .textCount

    override var intrinsicContentSize: NSSize { label.fittingSize }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }

    func setCount(_ count: Int) {
        label.stringValue = "\(titlePrefix) \(max(0, count))"
        invalidateIntrinsicContentSize()
    }

    func setStatusText(_ text: String?) {
        label.stringValue = text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "\(titlePrefix) 0"
        invalidateIntrinsicContentSize()
    }

    func setRecognitionKind(_ kind: RecognitionSlotKind) {
        recognitionKind = kind
        setCount(0)
    }

    func setEmphasized(_ emphasized: Bool) {
        label.textColor = emphasized ? DesignTokens.Color.textPrimary : DesignTokens.Color.textSecondary
    }

    private func configureView() {
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        label.font = DesignTokens.CountView.labelFont
        label.textColor = DesignTokens.Color.textSecondary
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private var titlePrefix: String {
        switch recognitionKind {
        case .textCount:
            return L10n.text(zhHans: "字数", en: "Words")
        case .fileCount:
            return L10n.text(zhHans: "文件", en: "Files")
        case .screenshotSize:
            return L10n.text(zhHans: "尺寸", en: "Size")
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
