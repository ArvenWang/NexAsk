import AppKit
import QuartzCore

package enum DesignTokens {
    private static var isSystemLightMode: Bool {
        guard let match = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) else { return false }
        return match == .aqua
    }

    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 6
        static let sm: CGFloat = 8
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
    }

    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 14
    }

    package enum Typography {
        // Result panel typography is isolated here first so later batches can add
        // more component-specific type without changing the views again.
        package static let settingsPageTitle = NSFont.systemFont(ofSize: 28, weight: .bold)
        package static let settingsPageSubtitle = NSFont.systemFont(ofSize: 13, weight: .regular)
        package static let settingsSidebarTitle = NSFont.systemFont(ofSize: 14, weight: .semibold)
        package static let settingsSectionTitle = NSFont.systemFont(ofSize: 13, weight: .semibold)
        package static let settingsSectionBody = NSFont.systemFont(ofSize: 12, weight: .regular)
        package static let settingsSectionNote = NSFont.systemFont(ofSize: 11, weight: .medium)
        package static let settingsFieldLabel = NSFont.systemFont(ofSize: 13, weight: .medium)
        package static let settingsButtonLabel = NSFont.systemFont(ofSize: 12, weight: .semibold)
        package static let settingsControlValue = NSFont.systemFont(ofSize: 13, weight: .medium)
        package static let settingsCardTitle = NSFont.systemFont(ofSize: 16, weight: .semibold)
        package static let settingsCardSubtitle = NSFont.systemFont(ofSize: 12, weight: .medium)
        package static let settingsBadge = NSFont.systemFont(ofSize: 11, weight: .medium)
        package static let settingsCatalogTitle = NSFont.systemFont(ofSize: 15, weight: .semibold)
        package static let settingsCatalogSummary = NSFont.systemFont(ofSize: 12, weight: .regular)
        package static let settingsCatalogMeta = NSFont.systemFont(ofSize: 11, weight: .medium)
        package static let settingsCatalogVersion = NSFont.systemFont(ofSize: 11, weight: .bold)
        package static let settingsCatalogState = NSFont.systemFont(ofSize: 11, weight: .semibold)
        package static let settingsDialogTitle = NSFont.systemFont(ofSize: 14, weight: .semibold)
        package static let settingsDialogSearch = NSFont.systemFont(ofSize: 15, weight: .regular)
        package static let settingsLearningHeader = NSFont.systemFont(ofSize: 18, weight: .semibold)
        package static let resultPanelTitle = NSFont.systemFont(ofSize: 17, weight: .semibold)
        package static let resultPanelBody = NSFont.systemFont(ofSize: 14, weight: .regular)
        package static let resultPanelRole = NSFont.systemFont(ofSize: 11, weight: .semibold)
        package static let resultPanelSectionHeader = NSFont.systemFont(ofSize: 11, weight: .semibold)
        package static let resultPanelStatus = NSFont.systemFont(ofSize: 13, weight: .medium)
        package static let resultPanelDetailMono = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        package static let resultPanelBadge = NSFont.systemFont(ofSize: 10, weight: .semibold)
        package static let resultPanelCardTitle = NSFont.systemFont(ofSize: 14, weight: .semibold)
        package static let resultPanelCardDescription = NSFont.systemFont(ofSize: 11, weight: .regular)
        package static let resultPanelCardURL = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        package static let resultPanelFooterButton = NSFont.systemFont(ofSize: 13, weight: .medium)
        package static let inlinePromptMessage = NSFont.systemFont(ofSize: 12.5, weight: .regular)
        package static let inlinePromptAction = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        package static let screenshotPreviewTitle = NSFont.systemFont(ofSize: 12, weight: .semibold)
        package static let screenshotPreviewMeta = NSFont.systemFont(ofSize: 11, weight: .medium)
        package static let screenshotDimension = NSFont.systemFont(
            ofSize: DesignTokens.Toolbar.fontSize,
            weight: DesignTokens.Toolbar.fontWeight
        )
        package static let screenshotTextEditorDefault = NSFont.systemFont(ofSize: 22, weight: .semibold)
    }

    package enum Semantic {
        package struct SurfacePair {
            package let fill: NSColor
            package let border: NSColor
        }

        package struct BadgePair {
            package let fill: NSColor
            package let border: NSColor
            package let text: NSColor
        }

        package enum ResultPanel {
            package enum Role {
                package static let userText = NSColor(calibratedRed: 0.70, green: 0.82, blue: 1.0, alpha: 0.95)
                package static let assistantText = NSColor(calibratedRed: 0.75, green: 0.94, blue: 0.80, alpha: 0.95)
                package static let toolText = NSColor(calibratedRed: 0.97, green: 0.82, blue: 0.60, alpha: 0.95)
                package static let systemText = DesignTokens.Color.textSecondary
            }

            package enum ToolBadge {
                package static let appearance = BadgePair(
                    fill: NSColor(calibratedRed: 0.33, green: 0.47, blue: 0.80, alpha: 0.14),
                    border: NSColor(calibratedRed: 0.54, green: 0.68, blue: 1, alpha: 0.22),
                    text: NSColor(calibratedRed: 0.78, green: 0.88, blue: 1, alpha: 0.96)
                )
            }

            package enum ActionCard {
                // Keep the existing green action-card language separate from the
                // blue trace-card language until product decides whether they
                // should converge into one semantic intent.
                package static let primaryRest = SurfacePair(
                    fill: NSColor(calibratedRed: 0.16, green: 0.52, blue: 0.36, alpha: 0.22),
                    border: NSColor(calibratedRed: 0.38, green: 0.76, blue: 0.56, alpha: 0.42)
                )
                package static let primaryHover = SurfacePair(
                    fill: NSColor(calibratedRed: 0.16, green: 0.52, blue: 0.36, alpha: 0.34),
                    border: NSColor(calibratedRed: 0.38, green: 0.76, blue: 0.56, alpha: 0.70)
                )
                package static let secondaryRest = SurfacePair(
                    fill: NSColor(calibratedWhite: 1, alpha: 0.055),
                    border: NSColor(calibratedWhite: 1, alpha: 0.11)
                )
                package static let secondaryHover = SurfacePair(
                    fill: NSColor(calibratedWhite: 1, alpha: 0.10),
                    border: NSColor(calibratedWhite: 1, alpha: 0.18)
                )
            }

            enum TraceCard {
                static let primaryRest = SurfacePair(
                    fill: NSColor(calibratedRed: 0.20, green: 0.38, blue: 0.78, alpha: 0.24),
                    border: NSColor(calibratedRed: 0.53, green: 0.69, blue: 0.98, alpha: 0.46)
                )
                static let primaryHover = SurfacePair(
                    fill: NSColor(calibratedRed: 0.20, green: 0.38, blue: 0.78, alpha: 0.34),
                    border: NSColor(calibratedRed: 0.53, green: 0.69, blue: 0.98, alpha: 0.70)
                )
                static let secondaryRest = SurfacePair(
                    fill: NSColor(calibratedWhite: 1, alpha: 0.055),
                    border: NSColor(calibratedWhite: 1, alpha: 0.11)
                )
                static let secondaryHover = SurfacePair(
                    fill: NSColor(calibratedWhite: 1, alpha: 0.10),
                    border: NSColor(calibratedWhite: 1, alpha: 0.18)
                )
                static let primaryIconText = NSColor(calibratedRed: 0.93, green: 0.93, blue: 0.95, alpha: 0.96)
                static let emphasisBadge = BadgePair(
                    fill: NSColor(calibratedRed: 0.50, green: 0.67, blue: 0.98, alpha: 0.22),
                    border: NSColor(calibratedRed: 0.64, green: 0.78, blue: 0.99, alpha: 0.34),
                    text: NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.99, alpha: 0.95)
                )
                static let neutralBadge = BadgePair(
                    fill: NSColor.white.withAlphaComponent(0.05),
                    border: NSColor.white.withAlphaComponent(0.1),
                    text: DesignTokens.Color.textSecondary.withAlphaComponent(0.92)
                )
            }
        }
    }

    enum Elevation {
        struct Shadow {
            let color: NSColor
            let opacity: Float
            let radius: CGFloat
            let offset: CGSize
        }

        // Result panel cards currently render as flat glass surfaces. This token
        // is added now so later batches can standardize shadow/elevation without
        // rethreading the component structure again.
        static let resultPanelCard = Shadow(
            color: .black,
            opacity: 0,
            radius: 0,
            offset: .zero
        )
    }

    package enum Settings {
        static let pageInset: CGFloat = 18
        static let controlHeight: CGFloat = 30
        static let compactControlHeight: CGFloat = 30
        static let controlSpacing: CGFloat = 8
        static let rowSpacing: CGFloat = 12

        package enum Page {
            package static let sidebarStackSpacing: CGFloat = 6
            package static let sidebarLeadingInset: CGFloat = 18
            package static let sidebarTopInset: CGFloat = 40
            package static let sidebarBottomInset: CGFloat = 26
            package static let surfaceGap: CGFloat = 18
            package static let surfaceInset: CGFloat = 18
            package static let indicatorTrailingInset: CGFloat = 7
            package static let indicatorVerticalInset: CGFloat = 12
            package static let titleTopInset: CGFloat = 8
            package static let contentTrailingInset: CGFloat = 6
            package static let stackSpacing: CGFloat = 18
            package static let plainSectionSpacing: CGFloat = 12
            package static let formRowSpacing: CGFloat = 8
            package static let checkboxLineSpacing: CGFloat = 28
            package static let filterRowSpacing: CGFloat = 14
            package static let skillListSpacing: CGFloat = 16
            package static let compactHeaderInset: CGFloat = 18
            package static let compactHeaderTopInset: CGFloat = 18
            package static let compactSectionSpacing: CGFloat = 12
            package static let compactButtonRowSpacing: CGFloat = 8
            package static let scrollContentInset: CGFloat = 18
            package static let learningStackSpacing: CGFloat = 14
            package static let learningHeaderSpacing: CGFloat = 8
        }

        enum Dialog {
            static let inset: CGFloat = 16
            static let listInset: CGFloat = 10
            static let verticalSpacing: CGFloat = 12
            static let footerSpacing: CGFloat = 14
            static let actionSpacing: CGFloat = 8
            static let searchFieldHeight: CGFloat = 40
            static let rowHorizontalInset: CGFloat = 12
            static let rowVerticalInset: CGFloat = 6
        }

        enum Sidebar {
            static let itemHeight: CGFloat = 42
            static let itemCornerRadius: CGFloat = 10
            static let itemInsetLeading: CGFloat = 14
            static let itemInsetTrailing: CGFloat = 12
            static let itemInsetVertical: CGFloat = 2
            static let selectedFill = DesignTokens.Settings.Card.hoverSurface
            static let selectedBorder = NSColor.clear
            static let selectedText = DesignTokens.Color.accentOrange
            static let defaultText = DesignTokens.Color.textSecondary
            static let hoverText = DesignTokens.Color.textPrimary
        }

        enum Card {
            static let cornerRadius: CGFloat = 8
            static let borderWidth: CGFloat = 1
            static let insetHorizontal: CGFloat = 14
            static let insetVertical: CGFloat = 12
            static let textSpacing: CGFloat = 8
            static let metaSpacing: CGFloat = 8
            static let actionTopSpacing: CGFloat = 12
            static let actionRowSpacing: CGFloat = 8
            static let surface = SkillCenter.Detail.sectionSurface
            static let border = SkillCenter.Detail.sectionBorder
            static let hoverSurface = NSColor(calibratedWhite: 1, alpha: 0.045)
            static let hoverBorder = DesignTokens.Color.border
            static let catalogCornerRadius: CGFloat = 14
            static let catalogInsetHorizontal: CGFloat = 16
            static let catalogInsetVertical: CGFloat = 16
            static let catalogIconPlateSize: CGFloat = 44
            static let catalogIconPlateCornerRadius: CGFloat = 11
            static let catalogIconPointSize: CGFloat = 22
            static let catalogHeaderSpacing: CGFloat = 12
            static let catalogMetaSpacing: CGFloat = 4
            static let catalogTitleTopSpacing: CGFloat = 16
            static let catalogTitleSummarySpacing: CGFloat = 8
            static let catalogSummaryLineSpacing: CGFloat = 3
            static let catalogActionTopSpacing: CGFloat = 16
            static let catalogActionSpacing: CGFloat = 12
            static let catalogPrimaryWidthRatio: CGFloat = 7.0 / 3.0
            static let catalogTitleColor = DesignTokens.Color.textPrimary.withAlphaComponent(0.96)
            static let catalogSummaryColor = DesignTokens.Color.textSecondary.withAlphaComponent(0.9)
            static let catalogVersionColor = DesignTokens.Color.textTertiary.withAlphaComponent(0.9)
            static let catalogStateColor = DesignTokens.Color.accentOrange
            static let catalogSurface = NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.11, alpha: 0.98)
            static let catalogBorder = NSColor(calibratedWhite: 1, alpha: 0.09)
            static let catalogHoverSurface = NSColor(calibratedRed: 0.13, green: 0.12, blue: 0.12, alpha: 0.99)
            static let catalogHoverBorder = DesignTokens.Color.accentOrangeBorder
            static let catalogSelectedSurface = NSColor(calibratedRed: 0.14, green: 0.11, blue: 0.10, alpha: 0.99)
            static let catalogSelectedBorder = DesignTokens.Color.accentOrangeStrongBorder
            static let catalogIconPlateFill = DesignTokens.Color.accentOrangeMutedPanel
            static let catalogIconPlateHoverFill = DesignTokens.Color.accentOrangeStrongFill
            static let catalogIconPlateSelectedFill = DesignTokens.Color.accentOrangeSoftFill
        }

        enum Input {
            static let cornerRadius: CGFloat = 8
            static let borderWidth: CGFloat = 1
            static let horizontalInset: CGFloat = 12
            static var surface: NSColor {
                DesignTokens.isSystemLightMode
                    ? NSColor(calibratedWhite: 1, alpha: 0.10)
                    : NSColor(calibratedWhite: 1, alpha: 0.055)
            }
            static var border: NSColor {
                DesignTokens.isSystemLightMode
                    ? NSColor(calibratedWhite: 1, alpha: 0.20)
                    : NSColor(calibratedWhite: 1, alpha: 0.14)
            }
            static var hoverSurface: NSColor {
                DesignTokens.isSystemLightMode
                    ? NSColor(calibratedWhite: 1, alpha: 0.12)
                    : NSColor(calibratedWhite: 1, alpha: 0.06)
            }
            static var hoverBorder: NSColor {
                DesignTokens.isSystemLightMode
                    ? NSColor(calibratedWhite: 1, alpha: 0.28)
                    : NSColor(calibratedWhite: 1, alpha: 0.24)
            }
            static var focusSurface: NSColor {
                DesignTokens.isSystemLightMode
                    ? NSColor(calibratedWhite: 0, alpha: 0.28)
                    : NSColor(calibratedWhite: 0, alpha: 0.22)
            }
            static var focusBorder: NSColor {
                DesignTokens.isSystemLightMode
                    ? NSColor(calibratedWhite: 1, alpha: 0.34)
                    : NSColor(calibratedWhite: 1, alpha: 0.28)
            }
        }

        enum Button {
            static let cornerRadius: CGFloat = 8
            static let borderWidth: CGFloat = 1
            static let horizontalPadding: CGFloat = 16
            static let minimumWidth: CGFloat = 72
            static let catalogPrimaryHeight: CGFloat = 34
            static let catalogPrimaryMinimumWidth: CGFloat = 120
            static let catalogPrimaryHorizontalPadding: CGFloat = 16
            static let catalogPrimaryCornerRadius: CGFloat = 10
            static let catalogSecondaryHeight: CGFloat = 34
            static let catalogSecondaryMinimumWidth: CGFloat = 52
            static let catalogSecondaryHorizontalPadding: CGFloat = 12
            static let catalogSecondaryCornerRadius: CGFloat = 10
            static let textOnlyHeight: CGFloat = 24
            static let textOnlyHorizontalPadding: CGFloat = 0
            static let surface = NSColor(
                calibratedRed: 48.0 / 255.0,
                green: 48.0 / 255.0,
                blue: 48.0 / 255.0,
                alpha: 1.0
            )
            static let border = NSColor(calibratedWhite: 1, alpha: 0.10)
            static let hoverSurface = NSColor(
                calibratedRed: 62.0 / 255.0,
                green: 62.0 / 255.0,
                blue: 62.0 / 255.0,
                alpha: 0.99
            )
            static let hoverBorder = NSColor(calibratedWhite: 1, alpha: 0.16)
            static let pressedSurface = NSColor(
                calibratedRed: 44.0 / 255.0,
                green: 44.0 / 255.0,
                blue: 44.0 / 255.0,
                alpha: 1.0
            )
            static let pressedBorder = NSColor(calibratedWhite: 1, alpha: 0.12)
            static let disabledSurface = surface.withAlphaComponent(0.42)
            static let disabledBorder = NSColor.clear
            static let disabledText = DesignTokens.Color.textTertiary.withAlphaComponent(0.56)
            static let accentSurface = surface
            static let accentBorder = border
            static let accentHoverSurface = DesignTokens.Color.accentOrangeStrongFill
            static let accentHoverBorder = DesignTokens.Color.accentOrangeStrongBorder
            static let accentText = DesignTokens.Color.textPrimary
            static let ghostSurface = NSColor.clear
            static let ghostBorder = NSColor.clear
            static let ghostHoverSurface = DesignTokens.Color.accentOrangeSoftFill
            static let ghostHoverBorder = DesignTokens.Color.accentOrangeBorder
            static let ghostText = DesignTokens.Color.textTertiary.withAlphaComponent(0.9)
            static let ghostHoverText = DesignTokens.Color.accentOrange
            static let textAction = DesignTokens.Color.accentOrange
            static let textActionHover = DesignTokens.Color.accentOrange.withAlphaComponent(0.86)
            static let textActionDisabled = DesignTokens.Color.textTertiary.withAlphaComponent(0.72)
        }

        enum Dropdown {
            static let cornerRadius: CGFloat = 10
            static let borderWidth: CGFloat = 1
            static let horizontalInset: CGFloat = 14
            static let indicatorInset: CGFloat = 12
            static var surface: NSColor { Input.surface }
            static var border: NSColor { Input.border }
            static var hoverSurface: NSColor { Input.hoverSurface }
            static var hoverBorder: NSColor { Input.hoverBorder }
            static var pressedSurface: NSColor { Input.focusSurface }
            static var pressedBorder: NSColor { Input.focusBorder }
        }

        enum TextBlock {
            static let cornerRadius: CGFloat = Card.cornerRadius
            static let horizontalInset: CGFloat = Card.insetHorizontal
            static let verticalInset: CGFloat = Card.insetVertical
            static let surface = Card.surface
            static let border = Card.border
        }

        enum Statistics {
            static let panelCornerRadius: CGFloat = 10
            static let panelBorderWidth: CGFloat = 1
            static let panelInset: CGFloat = 14
            static let panelSpacing: CGFloat = 12
            static let panelTopInset: CGFloat = 12
            static let panelBottomInset: CGFloat = 14
            static let metricGap: CGFloat = 10
            static let barHeight: CGFloat = 8
            static let trendHeight: CGFloat = 120
            static let metricValueSize: CGFloat = 22
            static let metricLabelSize: CGFloat = 11
            static let metricHeight: CGFloat = 92
            static let metricValueSpacing: CGFloat = 8
            static let metricNoteSpacing: CGFloat = 6
            static let metricLabelFont = NSFont.systemFont(ofSize: metricLabelSize, weight: .medium)
            static let metricValueFont = NSFont.systemFont(ofSize: metricValueSize, weight: .semibold)
            static let metricNoteFont = NSFont.systemFont(ofSize: 11, weight: .medium)
            static let metricTitleColor = DesignTokens.Color.textTertiary.withAlphaComponent(0.9)
            static let metricValueColor = DesignTokens.Color.textPrimary.withAlphaComponent(0.98)
            static let metricNoteColor = DesignTokens.Color.textSecondary.withAlphaComponent(0.88)

            static let sectionTitleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
            static let sectionTitleColor = DesignTokens.Color.textPrimary.withAlphaComponent(0.96)
            static let emptyFont = NSFont.systemFont(ofSize: 12, weight: .medium)
            static let emptyColor = DesignTokens.Color.textTertiary.withAlphaComponent(0.85)
            static let barRowSpacing: CGFloat = 10
            static let barValueLeading: CGFloat = 8
            static let barTrackTopSpacing: CGFloat = 6
            static let barTitleFont = emptyFont
            static let barTitleColor = routeValueColor
            static let barValueFont = emptyFont
            static let barValueColor = DesignTokens.Color.textSecondary.withAlphaComponent(0.84)
            static let trendAxisSpacing: CGFloat = 4
            static let trendAxisTopSpacing: CGFloat = 10
            static let trendAxisFont = NSFont.systemFont(ofSize: 10, weight: .medium)
            static let trendAxisColor = DesignTokens.Color.textTertiary.withAlphaComponent(0.82)
            static let trendCanvasCornerRadius: CGFloat = 8
            static let trendCanvasInsetX: CGFloat = 10
            static let trendCanvasInsetY: CGFloat = 12
            static let routeSummaryFont = NSFont.systemFont(ofSize: 12, weight: .medium)
            static let routeSummaryColor = DesignTokens.Color.textSecondary.withAlphaComponent(0.9)
            static let routeRowSpacing: CGFloat = 10
            static let routeKeyFont = NSFont.systemFont(ofSize: 11, weight: .medium)
            static let routeKeyColor = DesignTokens.Color.textTertiary.withAlphaComponent(0.86)
            static let routeValueFont = NSFont.systemFont(ofSize: 12, weight: .medium)
            static let routeValueColor = DesignTokens.Color.textPrimary.withAlphaComponent(0.93)
            static let routeEmptyFont = NSFont.systemFont(ofSize: 12, weight: .medium)
            static let routeEmptyColor = DesignTokens.Color.textTertiary.withAlphaComponent(0.84)

            static let panelSurface = NSColor(calibratedWhite: 1, alpha: 0.032)
            static let panelBorder = NSColor(calibratedWhite: 1, alpha: 0.075)
            static let chartTrack = NSColor(calibratedWhite: 1, alpha: 0.06)
            static let chartAccent = DesignTokens.Color.accentOrange
            static let trendStroke = DesignTokens.Color.accentOrange
            static let trendFill = DesignTokens.Color.accentOrange.withAlphaComponent(0.14)
            static let metricSurface = NSColor(calibratedWhite: 1, alpha: 0.04)
            static let metricBorder = NSColor(calibratedWhite: 1, alpha: 0.06)
        }

        enum Filter {
            static let height: CGFloat = 28
            static let horizontalPadding: CGFloat = 14
            static let cornerRadius: CGFloat = 8
            static let spacing: CGFloat = 14
            static let borderWidth: CGFloat = 1
            static let defaultFill = NSColor.clear
            static let hoverFill = NSColor(calibratedWhite: 1, alpha: 0.05)
            static let selectedFill = hoverFill
            static let pressedFill = NSColor(calibratedWhite: 1, alpha: 0.10)
            static let defaultBorder = NSColor.clear
            static let hoverBorder = NSColor.clear
            static let selectedBorder = NSColor.clear
            static let pressedBorder = NSColor.clear
            static let defaultText = DesignTokens.Color.textSecondary.withAlphaComponent(0.52)
            static let hoverText = DesignTokens.Color.textSecondary.withAlphaComponent(0.9)
            static let selectedText = DesignTokens.Color.accentOrange
        }

        enum Surface {
            static let contentCornerRadius: CGFloat = 8
            static let pageCornerRadius: CGFloat = 8
            static var pageFill: NSColor {
                DesignTokens.isSystemLightMode
                    ? NSColor(calibratedWhite: 0.075, alpha: 0.72)
                    : NSColor(calibratedWhite: 0.075, alpha: 0.48)
            }
            static var pageBorder: NSColor {
                DesignTokens.isSystemLightMode
                    ? NSColor(calibratedWhite: 1, alpha: 0.10)
                    : NSColor(calibratedWhite: 1, alpha: 0.055)
            }
        }

        package enum Status {
            package static let neutral = DesignTokens.Color.textSecondary
            package static let success = NSColor.systemGreen
            package static let warning = NSColor.systemOrange
        }
    }

    package enum ScrollIndicator {
        package static let width: CGFloat = 4
        package static let minThumbHeight: CGFloat = 36
        package static let cornerRadius: CGFloat = 3
        package static let emphasizedCornerRadius: CGFloat = 3.5
        package static let idleAlpha: CGFloat = 0.28
        package static let emphasizedAlpha: CGFloat = 0.46
        package static let trackInset: CGFloat = 1
        package static let trailingInset: CGFloat = 7
        package static let verticalInset: CGFloat = 12
        package static let showAnimationDuration: TimeInterval = 0.12
        package static let hideAnimationDuration: TimeInterval = 0.18
        package static let hideDelay: TimeInterval = 0.9
    }

    enum Motion {
        static let fast: TimeInterval = 0.12
        static let medium: TimeInterval = 0.18
    }

    // Centralized, non-essential visual effects.
    // Toggle each `isEnabled` to disable the entire effect without touching implementation code.
    package enum Effects {
        // Floating toolbar sweep that runs when the compact toolbar expands.
        enum ToolbarSweep {
            // Master switch for the toolbar glow pass.
            static let isEnabled = true
            static let radius: CGFloat = 72
            static let travelOvershoot: CGFloat = 28
            static let animationDuration: TimeInterval = 1.08
            static let verticalOffsetBelowBounds: CGFloat = 24
            static let wobbleAmplitude: CGFloat = 4
            static let secondaryScale: CGFloat = 0.82
            static let secondaryDelay: TimeInterval = 0.08
            static let secondaryYOffset: CGFloat = 6

            static let accentColor = NSColor(
                calibratedRed: 1,
                green: 78.0 / 255.0,
                blue: 30.0 / 255.0,
                alpha: 1
            )
            static let coreColor = NSColor(
                calibratedRed: 1,
                green: 0.87,
                blue: 0.78,
                alpha: 1
            )

            static let primaryAlphaScale: CGFloat = 1
            static let secondaryAlphaScale: CGFloat = 0.58
            static let primaryShadowRadius: CGFloat = 34
            static let secondaryShadowRadius: CGFloat = 24
            static let primaryShadowOpacity: Float = 1
            static let secondaryShadowOpacity: Float = 0.72
            // Border sweep rides along with the main toolbar glow and uses the same timing.
            static let borderLineWidth: CGFloat = 1
            static let borderGlowWidth: CGFloat = 176
            static let borderShadowRadius: CGFloat = 22
            static let borderShadowOpacity: Float = 0.62
            static let borderOpacityValues: [CGFloat] = [0, 0.62, 0.26, 0]
            static let borderOpacityKeyTimes: [NSNumber] = [0, 0.14, 0.62, 1]
            static let borderMidAlpha: CGFloat = 0.52
            static let borderCoreAlpha: CGFloat = 1

            static let gradientLocations: [NSNumber] = [0, 0.1, 0.28, 0.58, 1]
            static let primaryOpacityValues: [CGFloat] = [0, 1, 0.52, 0]
            static let primaryOpacityKeyTimes: [NSNumber] = [0, 0.11, 0.62, 1]
            static let wakeOpacityValues: [CGFloat] = [0, 0.52, 0.24, 0]
            static let wakeOpacityKeyTimes: [NSNumber] = [0, 0.14, 0.64, 1]
            static let primaryTransformKeyTimes: [NSNumber] = [0, 0.14, 0.56, 1]
            static let wakeTransformKeyTimes: [NSNumber] = [0, 0.16, 0.6, 1]

            static let timingControlPoints: (Float, Float, Float, Float) = (0.12, 0.88, 0.24, 1)
        }

        // Optional large ambient blobs for result-style panels.
        // Kept here so the panel background treatment can be revived or disabled from one place.
        enum ResultAmbient {
            // Master switch for the slower background blob treatment.
            static let isEnabled = true
            static let blobSize = CGSize(width: 320, height: 320)
            static let secondaryBlobSize = CGSize(width: 260, height: 260)
            static let tertiaryBlobSize = CGSize(width: 360, height: 360)
            static let primaryDuration: TimeInterval = 15
            static let secondaryDuration: TimeInterval = 19
            static let tertiaryDuration: TimeInterval = 23
            static let driftDistance: CGFloat = 44
            static let verticalDrift: CGFloat = 32
            static let cornerInset: CGFloat = 46
            static let centerGlowAlpha: CGFloat = 0.22
            static let midGlowAlpha: CGFloat = 0.12
            static let edgeGlowAlpha: CGFloat = 0
            static let shadowOpacity: Float = 0.34
            static let shadowRadius: CGFloat = 70
            static let primaryColor = NSColor(
                calibratedRed: 1,
                green: 120.0 / 255.0,
                blue: 64.0 / 255.0,
                alpha: 1
            )
            static let secondaryColor = NSColor(
                calibratedRed: 1,
                green: 170.0 / 255.0,
                blue: 108.0 / 255.0,
                alpha: 1
            )
            static let tertiaryColor = NSColor(
                calibratedRed: 1,
                green: 96.0 / 255.0,
                blue: 54.0 / 255.0,
                alpha: 1
            )
            static let gradientLocations: [NSNumber] = [0, 0.22, 0.62, 1]
            static let opacityValues: [CGFloat] = [0.2, 0.34, 0.24, 0.3, 0.2]
            static let opacityKeyTimes: [NSNumber] = [0, 0.28, 0.54, 0.8, 1]
        }

        // A calmer ambient treatment for conversation surfaces that should feel more like
        // a focused task console than a result showcase.
        enum ConversationAmbient {
            static let isEnabled = true
            static let blobSize = CGSize(width: 240, height: 240)
            static let secondaryBlobSize = CGSize(width: 208, height: 208)
            static let tertiaryBlobSize = CGSize(width: 260, height: 260)
            static let primaryDuration: TimeInterval = 18
            static let secondaryDuration: TimeInterval = 22
            static let tertiaryDuration: TimeInterval = 26
            static let driftDistance: CGFloat = 28
            static let verticalDrift: CGFloat = 20
            static let centerGlowAlpha: CGFloat = 0.14
            static let midGlowAlpha: CGFloat = 0.08
            static let edgeGlowAlpha: CGFloat = 0
            static let shadowOpacity: Float = 0.2
            static let shadowRadius: CGFloat = 56
            static let primaryColor = NSColor(
                calibratedRed: 0.44,
                green: 0.58,
                blue: 0.94,
                alpha: 1
            )
            static let secondaryColor = NSColor(
                calibratedRed: 0.94,
                green: 0.54,
                blue: 0.28,
                alpha: 1
            )
            static let tertiaryColor = NSColor(
                calibratedRed: 0.38,
                green: 0.78,
                blue: 0.72,
                alpha: 1
            )
            static let gradientLocations: [NSNumber] = [0, 0.24, 0.66, 1]
            static let opacityValues: [CGFloat] = [0.12, 0.2, 0.16, 0.18, 0.12]
            static let opacityKeyTimes: [NSNumber] = [0, 0.22, 0.52, 0.8, 1]
        }

        // Loading divider treatment used by the result panel:
        // a thin foreground line plus a larger, softer aura behind it.
        package enum ResultLoadingLine {
            // Master switch for the entire loading-line package.
            package static let isEnabled = true
            package static let lineThickness: CGFloat = 1
            package static let glowWidth: CGFloat = 224
            package static let glowInset: CGFloat = 8
            package static let edgeFadeWidth: CGFloat = 68
            package static let animationDuration: TimeInterval = 2.36
            package static let fadeDuration: TimeInterval = 0.42
            package static let auraWidthMultiplier: CGFloat = 2.6
            package static let auraHeight: CGFloat = 220
            package static let auraVerticalOffset: CGFloat = 3
            package static let auraOpacity: Float = 0.11
            package static let auraShadowOpacity: Float = 0.08
            package static let auraShadowRadius: CGFloat = 72
            package static let accentColor = NSColor(
                calibratedRed: 1,
                green: 82.0 / 255.0,
                blue: 24.0 / 255.0,
                alpha: 1
            )
            package static let coreColor = NSColor(
                calibratedRed: 1,
                green: 0.66,
                blue: 0.40,
                alpha: 1
            )
            package static let auraCoreColor = NSColor(
                calibratedRed: 1,
                green: 118.0 / 255.0,
                blue: 34.0 / 255.0,
                alpha: 1
            )
            package static let auraMidColor = NSColor(
                calibratedRed: 1,
                green: 80.0 / 255.0,
                blue: 18.0 / 255.0,
                alpha: 1
            )
            package static let trackColor = DesignTokens.Color.divider
            package static let glowOpacity: Float = 0.34
            package static let shadowOpacity: Float = 0.2
            package static let shadowRadius: CGFloat = 8
            package static let gradientLocations: [NSNumber] = [0, 0.24, 0.5, 0.76, 1]
            package static let auraGradientLocations: [NSNumber] = [0, 0.18, 0.44, 0.74, 1]
        }
    }

    package enum Color {
        package static var surfaceToolbar: NSColor {
            DesignTokens.isSystemLightMode
                ? NSColor(calibratedWhite: 0.07, alpha: 0.96)
                : NSColor(calibratedWhite: 0.07, alpha: 0.84)
        }
        package static var surfacePanel: NSColor { surfaceToolbar }
        package static var border: NSColor {
            DesignTokens.isSystemLightMode
                ? NSColor(calibratedWhite: 1, alpha: 0.18)
                : NSColor(calibratedWhite: 1, alpha: 0.12)
        }
        package static var divider: NSColor {
            DesignTokens.isSystemLightMode
                ? NSColor(calibratedWhite: 1, alpha: 0.12)
                : NSColor(calibratedWhite: 1, alpha: 0.08)
        }
        package static let controlFill = NSColor(calibratedWhite: 1, alpha: 0.07)
        package static let controlBorder = NSColor(calibratedWhite: 1, alpha: 0.13)
        package static let inputFill = NSColor(calibratedWhite: 1, alpha: 0.06)
        package static let inputBorder = NSColor(calibratedWhite: 1, alpha: 0.14)
        package static let inputText = NSColor(calibratedWhite: 0.92, alpha: 1)
        package static let inputPlaceholder = NSColor(calibratedWhite: 0.80, alpha: 0.78)
        package static let textPrimary = NSColor(calibratedWhite: 0.95, alpha: 1)
        package static let textSecondary = NSColor(calibratedWhite: 0.80, alpha: 1)
        package static let textTertiary = NSColor(calibratedWhite: 0.72, alpha: 1)
        package static let accentOrange = NSColor(calibratedRed: 0.92, green: 0.30, blue: 0.16, alpha: 1)
        package static let accentOrangeSoftFill = NSColor(calibratedRed: 0.92, green: 0.30, blue: 0.16, alpha: 0.12)
        package static let accentOrangeStrongFill = NSColor(calibratedRed: 0.92, green: 0.30, blue: 0.16, alpha: 0.18)
        package static let accentOrangeBorder = NSColor(calibratedRed: 0.96, green: 0.52, blue: 0.34, alpha: 0.30)
        package static let accentOrangeStrongBorder = NSColor(calibratedRed: 1.0, green: 0.58, blue: 0.38, alpha: 0.56)
        package static let accentOrangeMutedPanel = NSColor(calibratedRed: 0.26, green: 0.16, blue: 0.12, alpha: 0.72)
        package static let linkBlue = NSColor(calibratedRed: 0.67, green: 0.82, blue: 1, alpha: 0.97)
        package static let iconPrimary = NSColor(calibratedWhite: 0.93, alpha: 1)
        package static let hoverFill = NSColor(calibratedWhite: 1, alpha: 0.14)
    }

    enum Toolbar {
        static let height: CGFloat = 44
        static let compactHeight: CGFloat = 44
        static let minWidth: CGFloat = 0
        static let maxWidth: CGFloat = 420
        static let compactMinWidth: CGFloat = 0
        static let contentInsetLeading: CGFloat = 14
        static let contentInsetTrailing: CGFloat = 14
        static let compactInsetX: CGFloat = 14
        static let itemSpacing: CGFloat = 8
        static let avatarSize: CGFloat = 16
        static let controlHeight: CGFloat = 28
        static let chevronButtonSize: CGFloat = 28
        static let hoverHorizontalPadding: CGFloat = 10
        static let drawerStackSpacing: CGFloat = 6
        static let fontSize: CGFloat = 13
        static let fontWeight: NSFont.Weight = .semibold

        static var font: NSFont {
            .systemFont(ofSize: fontSize, weight: fontWeight)
        }

        enum ScreenshotControl {
            static let cancelTint = DesignTokens.Screenshot.Annotation.red
            static let confirmTint = DesignTokens.Screenshot.Annotation.green
        }
    }

    enum CountView {
        static let fontSize = DesignTokens.Toolbar.fontSize
        static let fontWeight = DesignTokens.Toolbar.fontWeight
        static let digitSpacing: CGFloat = -1
        static let contentSpacing: CGFloat = 5
        static let minimumAnimationInterval: TimeInterval = 0.045
        static let digitAnimationDuration: TimeInterval = 0.008
        static let digitAnimationLeadIn: TimeInterval = 0.006
        static let digitBaselineYOffset: CGFloat = -1
        static let digitHeightPadding: CGFloat = 2

        static var labelFont: NSFont {
            .systemFont(ofSize: fontSize, weight: fontWeight)
        }

        static var digitFont: NSFont {
            .monospacedDigitSystemFont(ofSize: fontSize, weight: fontWeight)
        }
    }

    enum KnowledgeBaseWindow {
        static let pageInset: CGFloat = 18
        static let verticalSpacing: CGFloat = 10
        static let sectionSpacing: CGFloat = 12
        static let fieldHeight: CGFloat = 32
        static let tabHeight: CGFloat = 28
        static let listInset: CGFloat = 12
        static let emptyWidthInset: CGFloat = 40
        static let closeBottomInset: CGFloat = 16
        static let statusBottomInset: CGFloat = 18
        static let actionSpacing: CGFloat = 8

        static let bodyFont = NSFont.systemFont(ofSize: 13)
        static let bodyColor = DesignTokens.Color.textSecondary
        static let hintFont = NSFont.systemFont(ofSize: 12)
        static let hintColor = DesignTokens.Color.textSecondary
        static let formatFont = NSFont.systemFont(ofSize: 12, weight: .medium)
        static let formatColor = DesignTokens.Color.textTertiary
        static let tokenFont = NSFont.systemFont(ofSize: 13)
        static let emptyFont = NSFont.systemFont(ofSize: 13)
        static let statusFont = NSFont.systemFont(ofSize: 12)
        static let statusColor = DesignTokens.Color.textSecondary

        enum Row {
            static let cornerRadius: CGFloat = 12
            static let borderWidth: CGFloat = 1
            static let horizontalInset: CGFloat = 14
            static let topInset: CGFloat = 12
            static let actionTopInset: CGFloat = 10
            static let titleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
            static let titleColor = DesignTokens.Color.textPrimary
            static let summaryFont = NSFont.systemFont(ofSize: 12)
            static let summaryColor = DesignTokens.Color.textSecondary
            static let metaFont = NSFont.systemFont(ofSize: 11, weight: .medium)
            static let metaColor = DesignTokens.Color.textTertiary
            static let titleSummarySpacing: CGFloat = 8
            static let summaryMetaSpacing: CGFloat = 8
            static let titleActionSpacing: CGFloat = 12
            static let actionSpacing: CGFloat = 8
            static let bottomInset: CGFloat = 12
            static let disabledSurface = NSColor.windowBackgroundColor.withAlphaComponent(0.55)
            static let enabledSurface = NSColor.windowBackgroundColor.withAlphaComponent(0.9)
            static let border = NSColor.separatorColor
        }
    }

    package enum ConversationPanel {
        package static let contentInsetX: CGFloat = 16
        package static let contentInsetY: CGFloat = 16
        package static let chromeSpacing: CGFloat = 4
        package static let transcriptStageInset: CGFloat = 0
        package static let stageCornerRadius: CGFloat = 16
        package static let composerCornerRadius: CGFloat = 12
        package static let stripCornerRadius: CGFloat = 12
        package static let stripBorderWidth: CGFloat = 1
        package static let stageBorderWidth: CGFloat = 1
        package static let buttonCornerRadius = DesignTokens.Settings.Button.cornerRadius
        package static let panelTintOpacity: CGFloat = 0.72
        package static let transcriptRowSpacing: CGFloat = 12

        package enum Typography {
            package static let title = NSFont.systemFont(ofSize: 18, weight: .semibold)
            package static let body = NSFont.systemFont(ofSize: 14, weight: .regular)
            package static let stripEyebrow = NSFont.systemFont(ofSize: 10, weight: .semibold)
            package static let stripTitle = NSFont.systemFont(ofSize: 12, weight: .semibold)
            package static let stripMeta = NSFont.systemFont(ofSize: 10, weight: .medium)
            package static let stripDetail = NSFont.systemFont(ofSize: 10, weight: .regular)
            package static let inlineMono = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
            package static let button = NSFont.systemFont(ofSize: 12, weight: .semibold)
        }

        package enum Surface {
            package static let stageFill = NSColor(calibratedWhite: 1, alpha: 0.024)
            package static let stageBorder = NSColor(calibratedWhite: 1, alpha: 0.075)
            package static let stageInsetFill = NSColor(calibratedWhite: 1, alpha: 0.018)

            package static let contextFill = NSColor(calibratedRed: 0.24, green: 0.32, blue: 0.52, alpha: 0.13)
            package static let contextBorder = NSColor(calibratedRed: 0.56, green: 0.67, blue: 0.96, alpha: 0.16)

            package static let sessionFill = NSColor(calibratedWhite: 1, alpha: 0.032)
            package static let sessionBorder = NSColor(calibratedWhite: 1, alpha: 0.08)

            package static let taskFill = NSColor(calibratedRed: 0.92, green: 0.30, blue: 0.16, alpha: 0.085)
            package static let taskBorder = NSColor(calibratedRed: 1, green: 0.58, blue: 0.38, alpha: 0.16)

            package static let approvalFill = NSColor(calibratedRed: 0.92, green: 0.30, blue: 0.16, alpha: 0.12)
            package static let approvalBorder = NSColor(calibratedRed: 1, green: 0.58, blue: 0.38, alpha: 0.22)

            package static var composerFill: NSColor { DesignTokens.Settings.Input.surface }
            package static var composerBorder: NSColor { DesignTokens.Settings.Input.border }
            package static var composerHoverFill: NSColor { DesignTokens.Settings.Input.hoverSurface }
            package static var composerHoverBorder: NSColor { DesignTokens.Settings.Input.hoverBorder }
            package static var composerFocusFill: NSColor { DesignTokens.Settings.Input.focusSurface }
            package static var composerFocusBorder: NSColor { DesignTokens.Settings.Input.focusBorder }

            package static let runtimeStepFill = NSColor(calibratedWhite: 1, alpha: 0.032)
            package static let runtimeStepBorder = NSColor(calibratedWhite: 1, alpha: 0.08)

            package static let codeFill = NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.14, alpha: 0.72)
            package static let codeBorder = NSColor(calibratedWhite: 1, alpha: 0.09)
            package static let codeDivider = NSColor(calibratedWhite: 1, alpha: 0.08)

            package static let userBubbleFill = NSColor(calibratedRed: 0.22, green: 0.32, blue: 0.54, alpha: 0.34)
            package static let userBubbleBorder = NSColor(calibratedRed: 0.54, green: 0.68, blue: 0.98, alpha: 0.28)
        }

        package enum Text {
            package static let eyebrow = DesignTokens.Color.textTertiary.withAlphaComponent(0.82)
            package static let title = DesignTokens.Color.textPrimary.withAlphaComponent(0.98)
            package static let meta = DesignTokens.Color.textSecondary.withAlphaComponent(0.9)
            package static let detail = DesignTokens.Color.textTertiary.withAlphaComponent(0.92)
            package static let muted = DesignTokens.Color.textSecondary.withAlphaComponent(0.58)
            package static let codeHeader = DesignTokens.Color.textSecondary.withAlphaComponent(0.9)
        }

        package enum Button {
            package static let sendFill = DesignTokens.Settings.Button.surface
            package static let sendFillHover = DesignTokens.Settings.Button.hoverSurface
            package static let sendBorder = DesignTokens.Settings.Button.border
            package static let sendBorderHover = DesignTokens.Settings.Button.hoverBorder
            package static let sendText = DesignTokens.Color.textPrimary

            package static let secondaryFill = DesignTokens.Settings.Button.surface
            package static let secondaryFillHover = DesignTokens.Settings.Button.hoverSurface
            package static let secondaryBorder = DesignTokens.Settings.Button.border
            package static let secondaryBorderHover = DesignTokens.Settings.Button.hoverBorder
            package static let secondaryText = DesignTokens.Color.textSecondary
            package static let secondaryTextHover = DesignTokens.Color.textPrimary

            package static let disabledFill = DesignTokens.Settings.Button.disabledSurface
            package static let disabledBorder = DesignTokens.Settings.Button.disabledBorder
            package static let disabledText = DesignTokens.Settings.Button.disabledText
        }
    }

    package enum ResultPanel {
        package static let stackSpacing: CGFloat = 10
        package static let transcriptRowSpacing: CGFloat = 10
        package static let contentInsetX: CGFloat = 14
        package static let contentInsetY: CGFloat = 12
        package static let langSpacing: CGFloat = 10
        package static let langControlHeight: CGFloat = 32
        package static let langControlMinWidth: CGFloat = 170
        package static let messageRoleSpacing: CGFloat = 4

        package enum ToolStatus {
            package static let titleSpacing: CGFloat = 7
            package static let detailSpacing: CGFloat = 12
            package static let detailTextColor = DesignTokens.Color.textTertiary.withAlphaComponent(0.46)
        }

        package enum Badge {
            package static let horizontalPadding: CGFloat = 9
            package static let height: CGFloat = 20
            package static let cornerRadius: CGFloat = 9
            package static let borderWidth: CGFloat = 1
            package static let baselineOffset: CGFloat = 2
        }

        package enum ActionCard {
            package static let cornerRadius = DesignTokens.Radius.md
            package static let borderWidth: CGFloat = 1
            package static let contentInset: CGFloat = 10
            package static let verticalSpacing: CGFloat = 3
            package static let titleRowSpacing: CGFloat = 8
            package static let arrowPointSize: CGFloat = 11
            package static let arrowDimension: CGFloat = 12
            package static let descriptionColor = DesignTokens.Color.textSecondary.withAlphaComponent(0.7)
            package static let actionTint = DesignTokens.Color.textSecondary.withAlphaComponent(0.9)
            package static let hoverAnimationDuration: TimeInterval = 0.16
        }

        enum TraceCard {
            static let cornerRadius = DesignTokens.Radius.md
            static let borderWidth: CGFloat = 1
            static let contentInset: CGFloat = 10
            static let verticalSpacing: CGFloat = 4
            static let titleRowSpacing: CGFloat = 8
            static let titleMetaSpacing: CGFloat = 6
            static let badgeSpacing: CGFloat = 6
            static let iconDimension: CGFloat = 14
            static let iconPointSize: CGFloat = 13
            static let arrowDimension: CGFloat = 12
            static let arrowPointSize: CGFloat = 12
            static let hoverAnimationDuration: TimeInterval = 0.16

            enum Badge {
                static let horizontalPadding: CGFloat = 6
                static let verticalPadding: CGFloat = 2
                static let cornerRadius: CGFloat = 7
                static let borderWidth: CGFloat = 1
            }
        }

        enum Footer {
            static let containerMinHeight: CGFloat = 30
            static let horizontalPadding: CGFloat = 10
            static let minHeight: CGFloat = 28
            static let cornerRadius = DesignTokens.Radius.sm
            static let disabledAlpha: CGFloat = 0.55
            static let hoverFill = DesignTokens.Color.hoverFill
        }

        enum ShimmeringStatus {
            static let duration: CFTimeInterval = 1.0
            static let highlightLocations: [NSNumber] = [0, 0.18, 0.36]
            static let fromLocations: [CGFloat] = [-0.55, -0.18, 0.12]
            static let toLocations: [CGFloat] = [0.88, 1.18, 1.52]
        }
    }

    enum InlinePrompt {
        static let initialSize = CGSize(width: 296, height: 44)
        static let minWidth: CGFloat = 248
        static let maxWidth: CGFloat = 340
        static let minHeight: CGFloat = 40
        static let contentHorizontalInset: CGFloat = 12
        static let contentVerticalInset: CGFloat = 10
        static let stackSpacing: CGFloat = 8
        static let viewportInset: CGFloat = 8
        static let anchorGap: CGFloat = 8
        static let widthPadding: CGFloat = 24
        static let heightPadding: CGFloat = 20

        static let warningColor = NSColor(calibratedRed: 0.98, green: 0.79, blue: 0.49, alpha: 0.96)
        static let actionColor = NSColor(calibratedRed: 0.67, green: 0.82, blue: 1, alpha: 0.97)

        static let iconPointSize: CGFloat = 13
        static let iconDimension: CGFloat = 14
        static let maxMessageLines: Int = 1
    }

    enum Screenshot {
        enum Annotation {
            static let red = NSColor.systemRed
            static let yellow = NSColor.systemYellow
            static let green = NSColor.systemGreen
            static let blue = NSColor.systemBlue

            static func textFont(ofSize size: CGFloat) -> NSFont {
                .systemFont(ofSize: size, weight: .semibold)
            }
        }

        enum Preview {
            static let panelSize = CGSize(width: 196, height: 188)
            static let imageHeight: CGFloat = 118
            static let outerGap: CGFloat = 12
            static let innerGap: CGFloat = 10
            static let edgeInset: CGFloat = 8
            static let horizontalInset: CGFloat = 14
            static let topInset: CGFloat = 12
            static let bottomInset: CGFloat = 12
            static let sectionSpacing: CGFloat = 10
            static let imageCornerRadius: CGFloat = 10
            static let imageSurface = NSColor.black.withAlphaComponent(0.22)
        }

        enum Editor {
            static let horizontalPadding: CGFloat = 10
            static let verticalPadding: CGFloat = 8
            static let minWidth: CGFloat = 96
            static let maxWidth: CGFloat = 280
            static let minHeight: CGFloat = 44
            static let contentMargin: CGFloat = 8
            static let cornerRadius: CGFloat = 10
            static let borderWidth: CGFloat = 1
            static let surface = NSColor.black.withAlphaComponent(0.28)
            static let border = NSColor.white.withAlphaComponent(0.18)
            static let insertionPoint = NSColor.white
            static let defaultTextColor = Annotation.red
            static let minTextContainerWidth: CGFloat = 40
            static let initialHeightExtra: CGFloat = 6
            static let measuredWidthPadding: CGFloat = 2
            static let usedRectHeightPadding: CGFloat = 2
        }

        enum Dimension {
            static let contentSpacing: CGFloat = 4
            static let digitSpacing: CGFloat = -1
        }
    }

    enum SkillCenter {
        enum Page {
            static let contentSpacing: CGFloat = 18
            static let horizontalInset: CGFloat = 28
            static let topInset: CGFloat = 18
            static let bottomInset: CGFloat = 18
            static let titleFont = NSFont.systemFont(ofSize: 36, weight: .bold)
            static let subtitleFont = NSFont.systemFont(ofSize: 14, weight: .medium)
            static let titleSubtitleSpacing: CGFloat = 6
            static let filterSpacing: CGFloat = 8
            static let listSpacing: CGFloat = 18
            static let sectionRowSpacing: CGFloat = 18
            static let minimumListHeight: CGFloat = 420
        }

        enum Button {
            static let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            static let cornerRadius: CGFloat = 10
            static let borderWidth: CGFloat = 1
            static let horizontalPadding: CGFloat = 22
            static let height: CGFloat = 32

            static let primaryBackground = DesignTokens.Color.controlFill
            static let primaryBackgroundHover = DesignTokens.Color.hoverFill
            static let primaryBorder = DesignTokens.Color.controlBorder
            static let primaryBorderHover = DesignTokens.Color.border
            static let primaryText = DesignTokens.Color.textPrimary

            static let secondaryBackground = DesignTokens.Color.controlFill
            static let secondaryBackgroundHover = DesignTokens.Color.hoverFill
            static let secondaryBorder = DesignTokens.Color.controlBorder
            static let secondaryBorderHover = DesignTokens.Color.border
            static let secondaryText = DesignTokens.Color.textSecondary
            static let secondaryTextHover = DesignTokens.Color.textPrimary

            // Keep these local to Skill Center for now; they reflect this surface's
            // existing destructive/filter language and are not yet promoted to a
            // cross-app semantic intent.
            static let destructiveBackground = DesignTokens.Color.controlFill
            static let destructiveBackgroundHover = NSColor(calibratedRed: 0.38, green: 0.16, blue: 0.18, alpha: 0.28)
            static let destructiveBorder = DesignTokens.Color.controlBorder
            static let destructiveBorderHover = NSColor(calibratedRed: 0.76, green: 0.34, blue: 0.38, alpha: 0.38)
            static let destructiveText = DesignTokens.Color.textPrimary

            static let filterBackground = DesignTokens.Color.controlFill
            static let filterBackgroundActive = DesignTokens.Color.hoverFill
            static let filterBorder = DesignTokens.Color.controlBorder
            static let filterBorderHover = DesignTokens.Color.border
            static let filterText = DesignTokens.Color.textSecondary
            static let filterTextActive = DesignTokens.Color.textPrimary
        }

        enum IconButton {
            static let cornerRadius: CGFloat = 12
            static let borderWidth: CGFloat = 1
            static let background = DesignTokens.Color.controlFill
            static let backgroundHover = DesignTokens.Color.hoverFill
            static let border = DesignTokens.Color.controlBorder
            static let borderHover = DesignTokens.Color.border
            static let text = DesignTokens.Color.textSecondary
            static let textHover = DesignTokens.Color.textPrimary
            static let size = CGSize(width: 36, height: 36)
            static let spacerSize = CGSize(width: 52, height: 36)
        }

        enum Tile {
            static let cornerRadius: CGFloat = 20
            static let borderWidth: CGFloat = 1
            static let iconPlateSize: CGFloat = 52
            static let iconPointSize: CGFloat = 28
            static let horizontalInset: CGFloat = 18
            static let verticalInset: CGFloat = 16
            static let rowSpacing: CGFloat = 14
            static let textSpacing: CGFloat = 6
            static let titleBadgeSpacing: CGFloat = 8
            static let titleFont = NSFont.systemFont(ofSize: 17, weight: .semibold)
            static let summaryFont = NSFont.systemFont(ofSize: 13, weight: .medium)
            static let iconPlateCornerRadius = DesignTokens.Radius.lg

            static let background = NSColor(calibratedWhite: 1, alpha: 0.05)
            static let backgroundHover = NSColor(calibratedWhite: 1, alpha: 0.08)
            static let backgroundSelected = NSColor(calibratedWhite: 1, alpha: 0.07)
            static let backgroundSelectedHover = NSColor(calibratedWhite: 1, alpha: 0.10)
            static let border = DesignTokens.Color.divider
            static let borderHover = DesignTokens.Color.border
            static let iconPlate = NSColor(calibratedWhite: 1, alpha: 0.08)
            static let iconPlateHover = NSColor(calibratedWhite: 1, alpha: 0.12)
            static let iconPlateSelected = NSColor(calibratedWhite: 1, alpha: 0.09)
            static let iconPlateSelectedHover = NSColor(calibratedWhite: 1, alpha: 0.12)
            static let titleText = DesignTokens.Color.textPrimary.withAlphaComponent(0.96)
            static let summaryText = DesignTokens.Color.textSecondary.withAlphaComponent(0.84)
        }

        enum Overlay {
            static let cornerRadius: CGFloat = 18
            static let borderWidth: CGFloat = 1
            static let width: CGFloat = 620
            static let maxHeight: CGFloat = 680
            static let outerInset: CGFloat = 32
            static let contentInset: CGFloat = 22
            static let stackSpacing: CGFloat = 20
            static let actionSpacing: CGFloat = 10
            static let checkboxFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
            static let footerFont = NSFont.systemFont(ofSize: 12, weight: .medium)
            static let shadowColor = NSColor.black.withAlphaComponent(0.28)
            static let shadowOpacity: Float = 1
            static let shadowRadius: CGFloat = 28
            static let shadowOffset = CGSize(width: 0, height: -2)
        }

        enum Detail {
            static let backdrop = NSColor(calibratedWhite: 0, alpha: 0.58)
            static let surface = NSColor(calibratedWhite: 0.06, alpha: 0.97)
            static let surfaceBorder = NSColor(calibratedWhite: 1, alpha: 0.08)
            static let sectionSurface = NSColor(calibratedWhite: 1, alpha: 0.025)
            static let sectionBorder = NSColor(calibratedWhite: 1, alpha: 0.07)
            static let updateIconTint = NSColor(calibratedWhite: 0.96, alpha: 1)
            static let titleText = DesignTokens.Color.textPrimary.withAlphaComponent(0.97)
            static let summaryText = DesignTokens.Color.textSecondary.withAlphaComponent(0.86)
            static let metaText = DesignTokens.Color.textTertiary.withAlphaComponent(0.84)

            static let titleFont = NSFont.systemFont(ofSize: 28, weight: .bold)
            static let summaryFont = NSFont.systemFont(ofSize: 15, weight: .medium)
            static let metaFont = NSFont.systemFont(ofSize: 12, weight: .medium)
            static let badgeSpacing: CGFloat = 8
            static let summarySpacing: CGFloat = 8
            static let badgeTopSpacing: CGFloat = 12
            static let metaSpacing: CGFloat = 10
            static let headerMinHeight: CGFloat = 136
            static let iconSize: CGFloat = 68
            static let headerIconSize: CGFloat = 52
            static let closeButtonSize: CGFloat = 36
            static let headerLeadingSpacing: CGFloat = 16
            static let trailingAccessorySpacing: CGFloat = 8
            static let titleTopOffset: CGFloat = 2

            enum Section {
                static let cornerRadius: CGFloat = 16
                static let borderWidth: CGFloat = 1
                static let inset: CGFloat = 16
                static let titleBodySpacing: CGFloat = 8
                static let titleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
                static let bodyFont = NSFont.systemFont(ofSize: 14, weight: .medium)
            }
        }

        enum EmptyState {
            static let cornerRadius: CGFloat = 18
            static let borderWidth: CGFloat = 1
            static let surface = NSColor(calibratedWhite: 1, alpha: 0.02)
            static let border = DesignTokens.Color.divider
            static let titleFont = NSFont.systemFont(ofSize: 22, weight: .bold)
            static let messageFont = NSFont.systemFont(ofSize: 14, weight: .medium)
            static let stackSpacing: CGFloat = 8
            static let minHeight: CGFloat = 160
            static let inset: CGFloat = 22
        }

        enum SectionHeader {
            static let titleFont = NSFont.systemFont(ofSize: 18, weight: .bold)
            static let countFont = NSFont.systemFont(ofSize: 12, weight: .medium)
            static let rowSpacing: CGFloat = 8
        }

        struct BadgeStyle {
            let fill: NSColor
            let border: NSColor
            let text: NSColor
        }

        enum Badge {
            static let cornerRadius: CGFloat = 8
            static let borderWidth: CGFloat = 1
            static let horizontalPadding: CGFloat = 8
            static let verticalPadding: CGFloat = 4
            static let font = NSFont.systemFont(ofSize: 11, weight: .medium)
            static let neutral = BadgeStyle(
                fill: DesignTokens.Color.controlFill,
                border: DesignTokens.Color.controlBorder,
                text: DesignTokens.Color.textSecondary.withAlphaComponent(0.92)
            )
            static let accent = BadgeStyle(
                fill: DesignTokens.Color.hoverFill,
                border: DesignTokens.Color.controlBorder,
                text: DesignTokens.Color.textPrimary.withAlphaComponent(0.96)
            )
            static let text = BadgeStyle(
                fill: NSColor(calibratedRed: 0.25, green: 0.39, blue: 0.74, alpha: 0.16),
                border: NSColor(calibratedRed: 0.35, green: 0.52, blue: 0.96, alpha: 0.24),
                text: NSColor(calibratedRed: 0.74, green: 0.83, blue: 1.0, alpha: 0.94)
            )
            static let file = BadgeStyle(
                fill: NSColor(calibratedRed: 0.38, green: 0.34, blue: 0.18, alpha: 0.18),
                border: NSColor(calibratedRed: 0.79, green: 0.67, blue: 0.29, alpha: 0.24),
                text: NSColor(calibratedRed: 0.98, green: 0.89, blue: 0.63, alpha: 0.94)
            )
            static let screenshot = BadgeStyle(
                fill: NSColor(calibratedRed: 0.18, green: 0.39, blue: 0.34, alpha: 0.18),
                border: NSColor(calibratedRed: 0.30, green: 0.74, blue: 0.62, alpha: 0.24),
                text: NSColor(calibratedRed: 0.72, green: 0.97, blue: 0.90, alpha: 0.94)
            )
            static let installed = BadgeStyle(
                fill: NSColor(calibratedRed: 0.26, green: 0.44, blue: 0.27, alpha: 0.18),
                border: NSColor(calibratedRed: 0.46, green: 0.78, blue: 0.49, alpha: 0.22),
                text: NSColor(calibratedRed: 0.79, green: 0.97, blue: 0.80, alpha: 0.94)
            )
            static let uninstalled = BadgeStyle(
                fill: NSColor(calibratedWhite: 1, alpha: 0.06),
                border: NSColor(calibratedWhite: 1, alpha: 0.12),
                text: DesignTokens.Color.textTertiary.withAlphaComponent(0.9)
            )
        }
    }
}
