import AppKit

package struct SettingsStatisticsMetricItem {
    package let title: String
    package let value: String
    package let note: String

    package init(title: String, value: String, note: String) {
        self.title = title
        self.value = value
        self.note = note
    }
}

struct SettingsStatisticsBarItem {
    let title: String
    let valueText: String
    let ratio: CGFloat
}

struct SettingsStatisticsTrendPoint {
    let label: String
    let value: Int
}

struct SettingsStatisticsRouteSnapshotModel {
    let title: String
    let summary: String
    let rows: [(String, String)]
}

private func styleStatisticsPanel(_ view: NSView) {
    view.wantsLayer = true
    view.layer?.cornerRadius = DesignTokens.Settings.Statistics.panelCornerRadius
    view.layer?.borderWidth = DesignTokens.Settings.Statistics.panelBorderWidth
    view.layer?.borderColor = DesignTokens.Settings.Statistics.panelBorder.cgColor
    view.layer?.backgroundColor = DesignTokens.Settings.Statistics.panelSurface.cgColor
}

package final class SettingsStatisticsMetricStripView: NSView {
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = DesignTokens.Settings.Statistics.metricGap
        stack.distribution = .fillEqually
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    package func update(items: [SettingsStatisticsMetricItem]) {
        stack.arrangedSubviews.forEach { view in
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        items.forEach { item in
            stack.addArrangedSubview(SettingsStatisticsMetricCardView(item: item))
        }
    }
}

private final class SettingsStatisticsMetricCardView: NSView {
    init(item: SettingsStatisticsMetricItem) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        styleStatisticsPanel(self)

        let titleLabel = NSTextField(labelWithString: item.title)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = DesignTokens.Settings.Statistics.metricLabelFont
        titleLabel.textColor = DesignTokens.Settings.Statistics.metricTitleColor

        let valueLabel = NSTextField(labelWithString: item.value)
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.font = DesignTokens.Settings.Statistics.metricValueFont
        valueLabel.textColor = DesignTokens.Settings.Statistics.metricValueColor

        let noteLabel = NSTextField(wrappingLabelWithString: item.note)
        noteLabel.translatesAutoresizingMaskIntoConstraints = false
        noteLabel.font = DesignTokens.Settings.Statistics.metricNoteFont
        noteLabel.textColor = DesignTokens.Settings.Statistics.metricNoteColor
        noteLabel.maximumNumberOfLines = 2

        addSubview(titleLabel)
        addSubview(valueLabel)
        addSubview(noteLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: DesignTokens.Settings.Statistics.metricHeight),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignTokens.Settings.Statistics.panelInset),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignTokens.Settings.Statistics.panelInset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: DesignTokens.Settings.Statistics.panelTopInset),

            valueLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignTokens.Settings.Statistics.panelInset),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignTokens.Settings.Statistics.panelInset),
            valueLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: DesignTokens.Settings.Statistics.metricValueSpacing),

            noteLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignTokens.Settings.Statistics.panelInset),
            noteLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignTokens.Settings.Statistics.panelInset),
            noteLabel.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: DesignTokens.Settings.Statistics.metricNoteSpacing),
            noteLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -DesignTokens.Settings.Statistics.panelTopInset)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class SettingsStatisticsBarSectionView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: L10n.text(zhHans: "还没有足够数据。", en: "Not enough data yet."))
    private let rowsStack = NSStackView()

    init(title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        styleStatisticsPanel(self)

        titleLabel.stringValue = title
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = DesignTokens.Settings.Statistics.sectionTitleFont
        titleLabel.textColor = DesignTokens.Settings.Statistics.sectionTitleColor

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = DesignTokens.Settings.Statistics.emptyFont
        emptyLabel.textColor = DesignTokens.Settings.Statistics.emptyColor
        emptyLabel.isHidden = true

        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.orientation = .vertical
        rowsStack.spacing = DesignTokens.Settings.Statistics.barRowSpacing
        rowsStack.alignment = .leading

        addSubview(titleLabel)
        addSubview(emptyLabel)
        addSubview(rowsStack)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignTokens.Settings.Statistics.panelInset),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignTokens.Settings.Statistics.panelInset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: DesignTokens.Settings.Statistics.panelTopInset),

            emptyLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            emptyLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            emptyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: DesignTokens.Settings.Statistics.panelSpacing),

            rowsStack.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            rowsStack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: DesignTokens.Settings.Statistics.panelSpacing),
            rowsStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DesignTokens.Settings.Statistics.panelBottomInset)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(items: [SettingsStatisticsBarItem]) {
        rowsStack.arrangedSubviews.forEach { view in
            rowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        emptyLabel.isHidden = !items.isEmpty
        rowsStack.isHidden = items.isEmpty

        items.forEach { item in
            let row = SettingsStatisticsBarRowView(item: item)
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }
    }
}

private final class SettingsStatisticsBarRowView: NSView {
    private let fill = NSView()
    private var fillWidthConstraint: NSLayoutConstraint?

    init(item: SettingsStatisticsBarItem) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: item.title)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = DesignTokens.Settings.Statistics.barTitleFont
        titleLabel.textColor = DesignTokens.Settings.Statistics.barTitleColor

        let valueLabel = NSTextField(labelWithString: item.valueText)
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.alignment = .right
        valueLabel.font = DesignTokens.Settings.Statistics.barValueFont
        valueLabel.textColor = DesignTokens.Settings.Statistics.barValueColor

        let track = NSView()
        track.translatesAutoresizingMaskIntoConstraints = false
        track.wantsLayer = true
        track.layer?.cornerRadius = DesignTokens.Settings.Statistics.barHeight / 2
        track.layer?.backgroundColor = DesignTokens.Settings.Statistics.chartTrack.cgColor

        fill.translatesAutoresizingMaskIntoConstraints = false
        fill.wantsLayer = true
        fill.layer?.cornerRadius = DesignTokens.Settings.Statistics.barHeight / 2
        fill.layer?.backgroundColor = DesignTokens.Settings.Statistics.chartAccent.cgColor
        track.addSubview(fill)

        addSubview(titleLabel)
        addSubview(valueLabel)
        addSubview(track)

        fillWidthConstraint = fill.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: max(0.04, min(item.ratio, 1)))
        fillWidthConstraint?.isActive = true

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor),

            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: DesignTokens.Settings.Statistics.barValueLeading),

            track.leadingAnchor.constraint(equalTo: leadingAnchor),
            track.trailingAnchor.constraint(equalTo: trailingAnchor),
            track.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: DesignTokens.Settings.Statistics.barTrackTopSpacing),
            track.heightAnchor.constraint(equalToConstant: DesignTokens.Settings.Statistics.barHeight),
            track.bottomAnchor.constraint(equalTo: bottomAnchor),

            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class SettingsStatisticsTrendSectionView: NSView {
    private let titleLabel = NSTextField(labelWithString: L10n.text(zhHans: "最近 7 天", en: "Last 7 Days"))
    private let chartView = SettingsStatisticsTrendCanvasView()
    private let axisStack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        styleStatisticsPanel(self)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = DesignTokens.Settings.Statistics.sectionTitleFont
        titleLabel.textColor = DesignTokens.Settings.Statistics.sectionTitleColor

        chartView.translatesAutoresizingMaskIntoConstraints = false
        chartView.heightAnchor.constraint(equalToConstant: DesignTokens.Settings.Statistics.trendHeight).isActive = true

        axisStack.translatesAutoresizingMaskIntoConstraints = false
        axisStack.orientation = .horizontal
        axisStack.distribution = .fillEqually
        axisStack.spacing = DesignTokens.Settings.Statistics.trendAxisSpacing

        addSubview(titleLabel)
        addSubview(chartView)
        addSubview(axisStack)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignTokens.Settings.Statistics.panelInset),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignTokens.Settings.Statistics.panelInset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: DesignTokens.Settings.Statistics.panelTopInset),

            chartView.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            chartView.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            chartView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: DesignTokens.Settings.Statistics.panelSpacing),

            axisStack.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            axisStack.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            axisStack.topAnchor.constraint(equalTo: chartView.bottomAnchor, constant: DesignTokens.Settings.Statistics.trendAxisTopSpacing),
            axisStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DesignTokens.Settings.Statistics.panelTopInset)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(points: [SettingsStatisticsTrendPoint]) {
        chartView.points = points.map(\.value)
        axisStack.arrangedSubviews.forEach { view in
            axisStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        points.forEach { point in
            let label = NSTextField(labelWithString: point.label)
            label.alignment = .center
            label.font = DesignTokens.Settings.Statistics.trendAxisFont
            label.textColor = DesignTokens.Settings.Statistics.trendAxisColor
            axisStack.addArrangedSubview(label)
        }
    }
}

private final class SettingsStatisticsTrendCanvasView: NSView {
    var points: [Int] = [] {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = DesignTokens.Settings.Statistics.trendCanvasCornerRadius
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard points.count > 1, let maxValue = points.max(), maxValue > 0 else { return }

        let insetBounds = bounds.insetBy(dx: DesignTokens.Settings.Statistics.trendCanvasInsetX, dy: DesignTokens.Settings.Statistics.trendCanvasInsetY)
        let stepX = insetBounds.width / CGFloat(max(points.count - 1, 1))
        let maxY = CGFloat(maxValue)

        let linePath = NSBezierPath()
        let fillPath = NSBezierPath()

        for (index, value) in points.enumerated() {
            let x = insetBounds.minX + CGFloat(index) * stepX
            let normalized = CGFloat(value) / maxY
            let y = insetBounds.minY + normalized * insetBounds.height
            let point = NSPoint(x: x, y: y)

            if index == 0 {
                linePath.move(to: point)
                fillPath.move(to: NSPoint(x: x, y: insetBounds.minY))
                fillPath.line(to: point)
            } else {
                linePath.line(to: point)
                fillPath.line(to: point)
            }
        }

        fillPath.line(to: NSPoint(x: insetBounds.maxX, y: insetBounds.minY))
        fillPath.close()

        DesignTokens.Settings.Statistics.trendFill.setFill()
        fillPath.fill()

        DesignTokens.Settings.Statistics.trendStroke.setStroke()
        linePath.lineWidth = 2
        linePath.lineJoinStyle = .round
        linePath.lineCapStyle = .round
        linePath.stroke()
    }
}

final class SettingsStatisticsRouteSnapshotView: NSView {
    private let titleLabel = NSTextField(labelWithString: L10n.text(zhHans: "最近一次系统判断", en: "Latest system decision"))
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        styleStatisticsPanel(self)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = DesignTokens.Settings.Statistics.sectionTitleFont
        titleLabel.textColor = DesignTokens.Settings.Statistics.sectionTitleColor

        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.font = DesignTokens.Settings.Statistics.routeSummaryFont
        summaryLabel.textColor = DesignTokens.Settings.Statistics.routeSummaryColor
        summaryLabel.maximumNumberOfLines = 0

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.spacing = DesignTokens.Settings.Statistics.routeRowSpacing
        stack.alignment = .leading

        addSubview(titleLabel)
        addSubview(summaryLabel)
        addSubview(stack)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignTokens.Settings.Statistics.panelInset),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignTokens.Settings.Statistics.panelInset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: DesignTokens.Settings.Statistics.panelTopInset),

            summaryLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            summaryLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            summaryLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: DesignTokens.Settings.Statistics.metricValueSpacing),

            stack.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            stack.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: DesignTokens.Settings.Statistics.panelSpacing),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DesignTokens.Settings.Statistics.panelBottomInset)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(model: SettingsStatisticsRouteSnapshotModel?) {
        stack.arrangedSubviews.forEach { view in
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        if let model {
            titleLabel.stringValue = model.title
            summaryLabel.stringValue = model.summary
            summaryLabel.isHidden = model.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            model.rows.forEach { key, value in
                let row = NSStackView()
                row.translatesAutoresizingMaskIntoConstraints = false
                row.orientation = .horizontal
                row.alignment = .firstBaseline
                row.spacing = DesignTokens.Settings.Statistics.routeRowSpacing

                let keyLabel = NSTextField(labelWithString: key)
                keyLabel.font = DesignTokens.Settings.Statistics.routeKeyFont
                keyLabel.textColor = DesignTokens.Settings.Statistics.routeKeyColor
                keyLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

                let valueLabel = NSTextField(wrappingLabelWithString: value)
                valueLabel.font = DesignTokens.Settings.Statistics.routeValueFont
                valueLabel.textColor = DesignTokens.Settings.Statistics.routeValueColor
                valueLabel.maximumNumberOfLines = 2

                row.addArrangedSubview(keyLabel)
                row.addArrangedSubview(valueLabel)
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        } else {
            titleLabel.stringValue = L10n.text(zhHans: "最近一次系统判断", en: "Latest system decision")
            summaryLabel.stringValue = ""
            summaryLabel.isHidden = true
            let emptyLabel = NSTextField(wrappingLabelWithString: L10n.text(zhHans: "还没有可展示的最近一次判断。先正常用一次划词入口，这里就会出现你的最近统计快照。", en: "There is no recent system decision to show yet. Use the text-selection entry once and your latest diagnostic snapshot will appear here."))
            emptyLabel.font = DesignTokens.Settings.Statistics.routeEmptyFont
            emptyLabel.textColor = DesignTokens.Settings.Statistics.routeEmptyColor
            emptyLabel.maximumNumberOfLines = 2
            stack.addArrangedSubview(emptyLabel)
            emptyLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }
}
