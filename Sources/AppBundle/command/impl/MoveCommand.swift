import AppKit
import Common

struct MoveCommand: Command {
    let args: MoveCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        let direction = args.direction.val
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let currentWindow = target.windowOrNil else {
            return .fail(io.err(noWindowIsFocused))
        }
        if await shouldFailBecauseFullscreen_nonCancellable(
            window: currentWindow,
            failIfFullscreen: args.failIfFullscreen,
            failIfMacosNativeFullscreen: args.failIfMacosNativeFullscreen,
        ) {
            return .fail
        }
        switch currentWindow.windowParentCases {
            case .unbound: return .fail
            case .tilingContainer(let parent):
                guard let indexOfCurrent = currentWindow.ownIndex else { return .fail(io.err(bugPrompt())) }
                let indexOfSiblingTarget = indexOfCurrent + direction.focusOffset
                if parent.orientation == direction.orientation && parent.children.indices.contains(indexOfSiblingTarget) {
                    switch parent.children[indexOfSiblingTarget].tilingTreeNodeCasesOrDie() {
                        case .tilingContainer(let topLevelSiblingTargetContainer):
                            return deepMoveIn(window: currentWindow, into: topLevelSiblingTargetContainer, moveDirection: direction, io)
                        case .window: // "swap windows"
                            let prevBinding = currentWindow.unbindFromParent()
                            currentWindow.bind(to: parent, adaptiveWeight: prevBinding.adaptiveWeight, index: indexOfSiblingTarget)
                            return .succ
                    }
                } else {
                    return moveOut(tilingWindow: currentWindow, direction: direction, io, args, env)
                }
            case .floatingWindowsContainer: // floating window
                return .fail(io.err("moving floating windows isn't yet supported")) // todo
            case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer:
                return .fail(io.err(moveOutMacosUnconventionalWindow))
            case .macosPopupWindowsContainer:
                return .fail(io.err(bugPrompt())) // Impossible
        }
    }
}

@MainActor private func hitWorkspaceBoundaries(
    _ window: Window,
    _ workspace: Workspace,
    _ io: CmdIo,
    _ args: MoveCmdArgs,
    _ direction: CardinalDirection,
    _ env: CmdEnv,
) -> BinaryExitCode {
    switch args.boundaries {
        case .workspace:
            switch args.boundariesAction {
                case .stop: return .succ
                case .fail: return .fail
                case .createImplicitContainer:
                    createImplicitContainerAndMoveWindow(window, workspace, direction)
                    return .succ
            }
        case .allMonitorsOuterFrame:
            guard let (monitors, index) = window.nodeMonitor?.findRelativeMonitor(inDirection: direction) else {
                return .fail(io.err("Should never happen. Can't find the current monitor"))
            }

            if monitors.indices.contains(index) {
                let moveNodeToMonitorArgs = MoveNodeToMonitorCmdArgs(target: .direction(direction))
                    .copy(\.windowId, window.windowId)
                    .copy(\.focusFollowsWindow, focus.windowOrNil == window)

                return MoveNodeToMonitorCommand(args: moveNodeToMonitorArgs).run(env, io)
            } else {
                return hitAllMonitorsOuterFrameBoundaries(window, workspace, args, direction)
            }
    }
}

@MainActor private func hitAllMonitorsOuterFrameBoundaries(
    _ window: Window,
    _ workspace: Workspace,
    _ args: MoveCmdArgs,
    _ direction: CardinalDirection,
) -> BinaryExitCode {
    switch args.boundariesAction {
        case .stop: return .succ
        case .fail: return .fail
        case .createImplicitContainer:
            createImplicitContainerAndMoveWindow(window, workspace, direction)
            return .succ
    }
}

private let moveOutMacosUnconventionalWindow = "moving macOS fullscreen, minimized windows and windows of hidden apps isn't yet supported. This behavior is subject to change"

@MainActor private func moveOut(
    tilingWindow window: Window,
    direction: CardinalDirection,
    _ io: CmdIo,
    _ args: MoveCmdArgs,
    _ env: CmdEnv,
) -> BinaryExitCode {
    let innerMostTilingContainer = window.parents.first(where: {
        return switch $0.parent?.cases {
            case .tilingContainer(let parent): parent.orientation == direction.orientation
            // Stop searching: we have hit the workspace
            case nil, .workspace: true
            // Impossible: tilingContainer's parent can only be a workspace or tilingContainer
            case .floatingWindowsContainer,
                 .macosMinimizedWindowsContainer,
                 .macosFullscreenWindowsContainer,
                 .macosHiddenAppsWindowsContainer,
                 .macosPopupWindowsContainer: true
        }
    }) as? TilingContainer
    guard let innerMostTilingContainer else { return .fail(io.err(bugPrompt())) } // Impossible
    if config.tilingInsertionMode == .bsp,
       let parent = window.parent as? TilingContainer,
       parent === innerMostTilingContainer,
       parent.orientation == direction.orientation
    {
        // `window` sits at the edge of a container that already runs along `direction`. Splitting that
        // container would give back `[window, [rest]]`, which normalization flattens into the very same
        // tree, so the move would be a silent no-op. Cross the edge into the neighbouring node instead.
        return bspMoveAcross(window, direction, io, args, env)
    }
    switch innerMostTilingContainer.tilingContainerParentCases {
        case .unbound: return .fail
        case .tilingContainer(let parent):
            check(parent.orientation == direction.orientation)
            guard insertTilingWindow(window, pushing: innerMostTilingContainer, direction) else {
                return .fail(io.err(bugPrompt()))
            }
            return .succ
        case .workspace(let parent):
            return hitWorkspaceBoundaries(window, parent, io, args, direction, env)
    }
}

/// Moves `window` past the edge of its container into whatever lies `direction`-ward of it, splitting the
/// leaf of that neighbour which faces `window`, the same way moving into a sibling container does.
@MainActor private func bspMoveAcross(
    _ window: Window,
    _ direction: CardinalDirection,
    _ io: CmdIo,
    _ args: MoveCmdArgs,
    _ env: CmdEnv,
) -> BinaryExitCode {
    var node: TreeNode = window
    while let parent = node.parent as? TilingContainer {
        if parent.orientation == direction.orientation,
           let index = node.ownIndex,
           let neighbour = parent.children.getOrNil(atIndex: index + direction.focusOffset)
        {
            guard let leaf = neighbour.findLeafWindowRecursive(snappedTo: direction.opposite),
                  insertTilingWindow(window, pushing: leaf, direction.opposite)
            else {
                return .fail(io.err(bugPrompt()))
            }
            return .succ
        }
        node = parent
    }
    guard let workspace = window.nodeWorkspace else { return .fail(io.err(bugPrompt())) }
    return hitWorkspaceBoundaries(window, workspace, io, args, direction, env)
}

@MainActor private func createImplicitContainerAndMoveWindow(
    _ window: Window,
    _ workspace: Workspace,
    _ direction: CardinalDirection,
) {
    let prevRoot = workspace.rootTilingContainer
    prevRoot.unbindFromParent()
    // Force tiles layout
    _ = TilingContainer(parent: workspace, adaptiveWeight: WEIGHT_AUTO, direction.orientation, .tiles, index: 0)
    check(prevRoot != workspace.rootTilingContainer)
    prevRoot.bind(to: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: 0)
    window.bind(to: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: direction.insertionOffset)
}

@MainActor private func deepMoveIn(window: Window, into container: TilingContainer, moveDirection: CardinalDirection, _ io: CmdIo) -> BinaryExitCode {
    switch config.tilingInsertionMode {
        case .bsp:
            // There is no room to grow a container in 'bsp', so the only way in is to split a leaf.
            // Moving right into a container means landing on the left of its leftmost window, hence
            // the two `opposite`s.
            guard let deepTarget = container.findLeafWindowRecursive(snappedTo: moveDirection.opposite),
                  insertTilingWindow(window, pushing: deepTarget, moveDirection.opposite)
            else {
                return .fail(io.err(bugPrompt()))
            }
            return .succ
        case .i3:
            let deepTarget = container.tilingTreeNodeCasesOrDie().findDeepMoveInTargetRecursive(moveDirection.orientation)
            switch deepTarget {
                case .tilingContainer(let deepTarget):
                    window.bind(to: deepTarget, adaptiveWeight: WEIGHT_AUTO, index: 0)
                case .window(let deepTarget):
                    guard let parent = deepTarget.parent as? TilingContainer else { return .fail(io.err(bugPrompt())) }
                    guard let deepTargetIndex = deepTarget.ownIndex else { return .fail(io.err(bugPrompt())) }
                    window.bind(to: parent, adaptiveWeight: WEIGHT_AUTO, index: deepTargetIndex + 1)
            }
            return .succ
    }
}

extension TilingTreeNodeCases {
    @MainActor fileprivate func findDeepMoveInTargetRecursive(_ orientation: Orientation) -> TilingTreeNodeCases {
        switch self {
            case .window:
                self
            case .tilingContainer(let container) where container.orientation == orientation:
                .tilingContainer(container)
            case .tilingContainer(let container):
                container.mostRecentChild.orDie("Empty containers must be detached during normalization")
                    .tilingTreeNodeCasesOrDie()
                    .findDeepMoveInTargetRecursive(orientation)
        }
    }
}

func shouldFailBecauseFullscreen_nonCancellable(
    window: Window,
    failIfFullscreen: Bool,
    failIfMacosNativeFullscreen: Bool,
) async -> Bool {
    if failIfFullscreen && window.isFullscreen {
        return true
    }
    if failIfMacosNativeFullscreen {
        if true == (try? await window.isMacosFullscreen(.nonCancellable)) {
            return true
        }
    }
    return false
}
