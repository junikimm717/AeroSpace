import Common

struct MoveNodeToWorkspaceCommand: Command {
    let args: MoveNodeToWorkspaceCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache: Bool = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }
        let subjectWs = window.nodeWorkspace
        let targetWorkspace: Workspace
        switch args.target.val {
            case .relative(let nextPrev):
                guard let subjectWs else { return .fail(io.err("Window \(window.windowId) doesn't belong to any workspace")) }
                let ws = getNextPrevWorkspace(
                    current: subjectWs,
                    isNext: nextPrev == .next,
                    wrapAround: args.wrapAround,
                    stdin: args.useStdin ? io.readStdin() : nil,
                    target: target,
                )
                guard let ws = ws.getOrNil(appendErrorTo: &io.stderr) else { return .fail }
                targetWorkspace = ws
            case .direct(let name):
                targetWorkspace = Workspace.get(byName: name.raw)
        }
        return moveWindowToWorkspace(window, targetWorkspace, io, focusFollowsWindow: args.focusFollowsWindow, failIfNoop: args.failIfNoop)
    }
}

/// - Parameter direction: set it when the window is crossing a monitor edge, so that it can land on
///   the side of the target workspace that faces where it came from instead of wherever focus was.
@MainActor
func moveWindowToWorkspace(
    _ window: Window,
    _ targetWorkspace: Workspace,
    _ io: CmdIo,
    focusFollowsWindow: Bool,
    failIfNoop: Bool,
    enteringFrom direction: CardinalDirection? = nil,
) -> BinaryExitCode {
    if window.nodeWorkspace == targetWorkspace {
        return switch failIfNoop {
            case true: .fail
            case false:
                .succ(io.err("Window '\(window.windowId)' already belongs to workspace '\(targetWorkspace.name)'. Tip: use --fail-if-noop to exit with non-zero code"))
        }
    }
    if window.isFloating {
        window.bind(to: targetWorkspace.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        return .from(bool: focusFollowsWindow ? window.focusWindow() : true)
    }
    // `window` lives in another workspace, so it can never be picked as its own insertion anchor here
    let root = targetWorkspace.rootTilingContainer
    switch config.tilingInsertionMode {
        case .i3:
            let index = true == direction.map { $0.isPositive && root.orientation == $0.orientation }
                ? 0
                : INDEX_BIND_LAST
            window.bind(to: root, adaptiveWeight: WEIGHT_AUTO, index: index)
        case .bsp:
            // There is no room to append to the root container, so split the window that already
            // occupies the edge the move is arriving at
            let entry = direction?.opposite
            let edgeWindow = entry.flatMap { root.findLeafWindowRecursive(snappedTo: $0) }
            let landed = if let entry, let edgeWindow {
                insertTilingWindow(window, pushing: edgeWindow, entry)
            } else {
                false
            }
            if !landed { // No direction to enter from, or the workspace is empty
                window.bindAsTilingWindow(at: tilingInsertionPoint(in: targetWorkspace))
            }
    }
    return .from(bool: focusFollowsWindow ? window.focusWindow() : true)
}
