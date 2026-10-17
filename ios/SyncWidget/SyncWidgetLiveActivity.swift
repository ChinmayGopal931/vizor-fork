//
//  SyncWidgetLiveActivity.swift
//  SyncWidget
//

import ActivityKit
import SwiftUI
import WidgetKit

/// The sync and transaction Live Activities, in the mobile neon look (see
/// "Mobile neon redesign" in AGENTS.md): true black, a neon-red tube with a
/// pale core, thin and light system type, and tracked uppercase captions.
///
/// The app writes each state into the shared app group under the activity's
/// prefixed keys (`displayMode`, `percentage`, `status`, `txStatus`); this
/// file only reads them.
struct SyncWidgetLiveActivity: Widget {
    let appGroupId = "group.com.keplr.vizor"

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LiveActivitiesAppAttributes.self) { context in
            // Lock Screen banner
            let sharedDefault = UserDefaults(suiteName: appGroupId)!
            let displayMode = sharedDefault.string(forKey: context.attributes.prefixedKey("displayMode")) ?? "sync"

            Group {
                if displayMode == "txTrack" {
                    txTrackBanner(context: context, defaults: sharedDefault)
                } else {
                    syncBanner(context: context, defaults: sharedDefault)
                }
            }
            .activityBackgroundTint(NeonActivityPalette.black)
            .activitySystemActionForegroundColor(NeonActivityPalette.core)

        } dynamicIsland: { context in
            let sharedDefault = UserDefaults(suiteName: appGroupId)!
            let displayMode = sharedDefault.string(forKey: context.attributes.prefixedKey("displayMode")) ?? "sync"

            if displayMode == "txTrack" {
                return txTrackIsland(context: context, defaults: sharedDefault)
            } else {
                return syncIsland(context: context, defaults: sharedDefault)
            }
        }
    }

    // MARK: - Sync UI

    private func syncBanner(context: ActivityViewContext<LiveActivitiesAppAttributes>, defaults: UserDefaults) -> some View {
        let percentage = Double(defaults.string(forKey: context.attributes.prefixedKey("percentage")) ?? "0") ?? 0

        return NeonSyncBanner(percentage: percentage)
    }

    private func syncIsland(context: ActivityViewContext<LiveActivitiesAppAttributes>, defaults: UserDefaults) -> DynamicIsland {
        let percentage = Double(defaults.string(forKey: context.attributes.prefixedKey("percentage")) ?? "0") ?? 0
        let status = defaults.string(forKey: context.attributes.prefixedKey("status")) ?? "Syncing..."

        return DynamicIsland {
            DynamicIslandExpandedRegion(.leading) {
                NeonSyncIslandLeading()
            }
            DynamicIslandExpandedRegion(.trailing) {
                NeonPercentText(percentage: percentage, size: 26)
                    .padding(.trailing, 4)
            }
            DynamicIslandExpandedRegion(.bottom) {
                NeonSyncIslandBottom(percentage: percentage, status: status)
            }
        } compactLeading: {
            NeonLitSquare(size: 7)
        } compactTrailing: {
            NeonCompactPercentText(percentage: percentage)
        } minimal: {
            NeonLitSquare(size: 7)
        }
        .keylineTint(NeonActivityPalette.red)
    }

    // MARK: - TX Tracking UI

    private func txTrackBanner(context: ActivityViewContext<LiveActivitiesAppAttributes>, defaults: UserDefaults) -> some View {
        let status = defaults.string(forKey: context.attributes.prefixedKey("status")) ?? "Tracking transactions"
        let txStatus = defaults.string(forKey: context.attributes.prefixedKey("txStatus")) ?? "pending"
        let isDone = txStatus == "done"

        return NeonTxBanner(status: status, isDone: isDone)
    }

    private func txTrackIsland(context: ActivityViewContext<LiveActivitiesAppAttributes>, defaults: UserDefaults) -> DynamicIsland {
        let status = defaults.string(forKey: context.attributes.prefixedKey("status")) ?? "Tracking"
        let txStatus = defaults.string(forKey: context.attributes.prefixedKey("txStatus")) ?? "pending"
        let isDone = txStatus == "done"

        return DynamicIsland {
            DynamicIslandExpandedRegion(.leading) {
                NeonTxGlyph(isDone: isDone, size: 18)
                    .padding(.leading, 4)
            }
            DynamicIslandExpandedRegion(.trailing) {
                if !isDone {
                    NeonSpinner()
                        .padding(.trailing, 4)
                }
            }
            DynamicIslandExpandedRegion(.bottom) {
                NeonStatusText(text: status, isDone: isDone, size: 13)
                    .padding(.horizontal, 4)
            }
        } compactLeading: {
            NeonTxGlyph(isDone: isDone, size: 13)
        } compactTrailing: {
            if isDone {
                NeonCheckGlyph(size: 12)
            } else {
                NeonSpinner()
            }
        } minimal: {
            NeonTxGlyph(isDone: isDone, size: 13)
        }
        .keylineTint(NeonActivityPalette.red)
    }
}

// MARK: - Neon look
//
// Plain SwiftUI from here on (no ActivityKit or WidgetKit types), so the
// views can also be rendered outside a Live Activity.

/// The neon palette, from `NeonPrimitives` in the app's `primitives.dart`.
enum NeonActivityPalette {
    static let black = Color.black

    /// The tube colour (#FF2E3E).
    static let red = Color(red: 1, green: 46 / 255, blue: 62 / 255)

    /// The white-hot centre of a lit tube (#FFE4E7).
    static let core = Color(red: 1, green: 228 / 255, blue: 231 / 255)

    /// The unlit rest of a track.
    static let unlit = red.opacity(0.2)
}

extension View {
    /// Lights a glyph or a line as a neon tube: a tight red glow and a wider
    /// halo. Pair with `NeonActivityPalette.core` for a white-hot glyph.
    func neonGlow(_ intensity: Double = 1) -> some View {
        let k = min(max(intensity, 0), 1)
        return self
            .shadow(color: NeonActivityPalette.red.opacity(0.9 * k), radius: 1.5)
            .shadow(color: NeonActivityPalette.red.opacity(0.55 * k), radius: 5)
            .shadow(color: NeonActivityPalette.red.opacity(0.3 * k), radius: 11)
    }
}

/// A HUD caption: tracked uppercase, red unless told otherwise.
struct NeonCaption: View {
    let text: String
    var color: Color = NeonActivityPalette.red
    var size: CGFloat = 11

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: size, weight: .regular))
            .tracking(size * 0.22)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

/// A small lit square, the head of the app's sync line: red with a white-hot
/// centre.
struct NeonLitSquare: View {
    var size: CGFloat = 8
    var intensity: Double = 1

    var body: some View {
        Rectangle()
            .fill(NeonActivityPalette.red)
            .overlay(
                Rectangle()
                    .fill(NeonActivityPalette.core)
                    .padding(size * 0.3)
            )
            .frame(width: size, height: size)
            .neonGlow(intensity)
            .accessibilityHidden(true)
    }
}

/// A thin red line that lights up with progress, with the lit square at its
/// head, as the sync line on Home does.
struct NeonProgressLine: View {
    let progress: Double

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let lit = width * min(max(progress, 0), 1)
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(NeonActivityPalette.unlit)
                    .frame(height: 1)
                Rectangle()
                    .fill(NeonActivityPalette.red)
                    .frame(width: lit, height: 2)
                    .neonGlow(0.8)
                Rectangle()
                    .fill(NeonActivityPalette.core.opacity(0.85))
                    .frame(width: lit, height: 0.6)
                NeonLitSquare(size: 6)
                    .offset(x: lit - 3)
            }
            .frame(width: width, height: geometry.size.height)
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

/// The sync percentage as the app's balance sign: thin numerals in the pale
/// core, lit red, and a red percent sign.
struct NeonPercentText: View {
    let percentage: Double
    var size: CGFloat = 30

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text("\(Int(percentage * 100))")
                .font(.system(size: size, weight: .thin))
                .monospacedDigit()
                .foregroundStyle(NeonActivityPalette.core)
                .neonGlow()
            Text("%")
                .font(.system(size: size * 0.45, weight: .light))
                .foregroundStyle(NeonActivityPalette.red)
                .neonGlow(0.5)
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

/// The percentage beside the camera in the compact Dynamic Island.
struct NeonCompactPercentText: View {
    let percentage: Double

    var body: some View {
        Text("\(Int(percentage * 100))%")
            .font(.system(size: 14, weight: .light))
            .monospacedDigit()
            .foregroundStyle(NeonActivityPalette.core)
            .neonGlow(0.6)
            .lineLimit(1)
    }
}

/// The expanded island's leading region for sync: the lit square and the
/// wordmark caption.
struct NeonSyncIslandLeading: View {
    var body: some View {
        HStack(spacing: 8) {
            NeonLitSquare(size: 8)
            NeonCaption(text: "Veylor")
        }
        .padding(.leading, 4)
    }
}

/// The expanded island's bottom region for sync: the line and the status.
struct NeonSyncIslandBottom: View {
    let percentage: Double
    let status: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            NeonProgressLine(progress: percentage)
            NeonCaption(text: status, color: NeonActivityPalette.red.opacity(0.75), size: 10)
        }
        .padding(.horizontal, 4)
    }
}

/// The 45° cut square of the redesign's buttons and badges, as an outline.
struct NeonChamferShape: Shape {
    /// How far each cut reaches along an edge, as a share of the side.
    var cut: CGFloat = 0.3

    func path(in rect: CGRect) -> Path {
        let c = min(rect.width, rect.height) * cut
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + c, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - c, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + c))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - c))
        path.addLine(to: CGPoint(x: rect.maxX - c, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + c, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - c))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + c))
        path.closeSubpath()
        return path
    }
}

/// A hard-cornered check mark.
struct NeonCheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.10, y: rect.minY + rect.height * 0.52))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.minY + rect.height * 0.80))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.92, y: rect.minY + rect.height * 0.22))
        return path
    }
}

/// Done: a white-hot check lit red.
struct NeonCheckGlyph: View {
    var size: CGFloat = 16

    var body: some View {
        NeonCheckShape()
            .stroke(
                NeonActivityPalette.core,
                style: StrokeStyle(lineWidth: max(1.5, size * 0.13), lineCap: .square, lineJoin: .miter)
            )
            .frame(width: size, height: size)
            .neonGlow()
            .accessibilityHidden(true)
    }
}

/// Pending: an open red frame with 45° cuts and the lit square waiting inside.
struct NeonPendingGlyph: View {
    var size: CGFloat = 16

    var body: some View {
        ZStack {
            NeonChamferShape()
                .stroke(
                    NeonActivityPalette.red,
                    style: StrokeStyle(lineWidth: max(1.1, size * 0.08), lineJoin: .miter)
                )
                .neonGlow(0.6)
            NeonLitSquare(size: max(3, size * 0.28), intensity: 0.8)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The transaction tracker's glyph for its state.
struct NeonTxGlyph: View {
    let isDone: Bool
    var size: CGFloat = 16

    var body: some View {
        if isDone {
            NeonCheckGlyph(size: size)
        } else {
            NeonPendingGlyph(size: size)
        }
    }
}

/// The system activity indicator, lit red.
struct NeonSpinner: View {
    var body: some View {
        ProgressView()
            .tint(NeonActivityPalette.red)
    }
}

/// The transaction status line: white-hot once done, red while pending.
struct NeonStatusText: View {
    let text: String
    let isDone: Bool
    var size: CGFloat = 15

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .light))
            .foregroundStyle(isDone ? NeonActivityPalette.core : NeonActivityPalette.red)
            .neonGlow(isDone ? 0.6 : 0.3)
            .lineLimit(2)
    }
}

/// The lock screen banner while syncing.
struct NeonSyncBanner: View {
    let percentage: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                NeonLitSquare(size: 8)
                NeonCaption(text: "Veylor sync")
                Spacer(minLength: 8)
                NeonPercentText(percentage: percentage)
            }
            NeonProgressLine(progress: percentage)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(NeonActivityPalette.black)
    }
}

/// The lock screen banner while transactions are tracked.
struct NeonTxBanner: View {
    let status: String
    let isDone: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                NeonTxGlyph(isDone: isDone, size: 14)
                NeonCaption(text: "Zcash transaction")
                Spacer(minLength: 8)
                if !isDone {
                    NeonSpinner()
                }
            }
            NeonStatusText(text: status, isDone: isDone)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(NeonActivityPalette.black)
    }
}
