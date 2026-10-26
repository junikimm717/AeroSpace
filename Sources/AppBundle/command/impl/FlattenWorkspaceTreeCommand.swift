import AppKit
import Common

struct FlattenWorkspaceTreeCommand: Command {
    let args: FlattenWorkspaceTreeCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache: Bool = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        let workspace = target.workspace
        let prevRoot = workspace.rootTilingContainer
        let windows = prevRoot.allLeafWindowsRecursive
        switch config.tilingInsertionMode {
            case .i3:
                for window in windows {
                    window.bind(to: workspace.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
                }
            case .bsp:
                // A single container can't hold every window in 'bsp', so "flatten" means the nearest
                // equivalent: rebuild the workspace as a balanced tree where every window gets the
                // same area, regardless of how lopsided the tree had become
                if windows.count < 2 { return .succ }
                let rect = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
                for window in windows { window.unbindFromParent() }
                prevRoot.unbindFromParent()
                buildBalancedBspTree(windows, parent: workspace, weight: 1, width: rect.width, height: rect.height)
        }
        return .succ
    }
}

/// Binds `windows` under `parent` as a balanced binary tree, splitting the longer side at every level.
///
/// An odd split gives each half space in proportion to how many windows it holds, so every window
/// ends up with the same area. `weight` is the size `parent` allots along its own orientation: the
/// tiles layout spreads any leftover space evenly across children rather than proportionally, so
/// weights have to be real dimensions and not ratios.
@MainActor
private func buildBalancedBspTree(
    _ windows: [Window],
    parent: NonLeafTreeNodeObject,
    weight: CGFloat,
    width: CGFloat,
    height: CGFloat,
) {
    if let window = windows.singleOrNil() {
        window.bind(to: parent, adaptiveWeight: weight, index: INDEX_BIND_LAST)
        return
    }
    guard windows.count > 1 else { return }
    let orientation: Orientation = width >= height ? .h : .v
    let container = TilingContainer(parent: parent, adaptiveWeight: weight, orientation, .tiles, index: INDEX_BIND_LAST)
    let split = windows.count / 2
    let first = Array(windows[..<split])
    let second = Array(windows[split...])
    switch orientation {
        case .h:
            let firstWidth = width * CGFloat(split) / CGFloat(windows.count)
            buildBalancedBspTree(first, parent: container, weight: firstWidth, width: firstWidth, height: height)
            buildBalancedBspTree(second, parent: container, weight: width - firstWidth, width: width - firstWidth, height: height)
        case .v:
            let firstHeight = height * CGFloat(split) / CGFloat(windows.count)
            buildBalancedBspTree(first, parent: container, weight: firstHeight, width: width, height: firstHeight)
            buildBalancedBspTree(second, parent: container, weight: height - firstHeight, width: width, height: height - firstHeight)
    }
}
