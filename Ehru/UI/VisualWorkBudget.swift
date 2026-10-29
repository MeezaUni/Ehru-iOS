import SwiftUI

/// Adapt decorative work to the device without reducing audio or downloaded artwork quality.
struct VisualWorkBudget: Equatable {
    let lowPower: Bool
    let thermalState: ProcessInfo.ThermalState

    static var current: VisualWorkBudget {
        VisualWorkBudget(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                         thermalState: ProcessInfo.processInfo.thermalState)
    }

    var allowsDecorativeMotion: Bool {
        !lowPower && thermalState != .serious && thermalState != .critical
    }

    var visualizerInterval: TimeInterval { allowsDecorativeMotion ? 1.0 / 60 : 1.0 / 20 }
}

private struct VisualWorkBudgetKey: EnvironmentKey {
    static let defaultValue = VisualWorkBudget(lowPower: false, thermalState: .nominal)
}

extension EnvironmentValues {
    var visualWorkBudget: VisualWorkBudget {
        get { self[VisualWorkBudgetKey.self] }
        set { self[VisualWorkBudgetKey.self] = newValue }
    }
}

extension View {
    /// Scroll visibility changes only at threshold crossings, rather than publishing geometry
    /// each frame. Older systems still use the view's normal appearance/disappearance hooks.
    @ViewBuilder
    func reportsScrollVisibility(enabled: Bool = true, _ action: @escaping (Bool) -> Void) -> some View {
        if #available(iOS 18.0, *), enabled {
            self.onScrollVisibilityChange(threshold: 0.15, action)
        } else { self }
    }
}
