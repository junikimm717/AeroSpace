import AppKit
import Common

/// How a window that enters the tiling tree is placed relative to the window it lands next to.
enum TilingInsertionMode: String {
    /// i3-like. The new window becomes a sibling of the anchor, so a single container can end up
    /// holding arbitrarily many windows side by side.
    case i3
    /// bspwm-like. The new window splits the anchor in two, so every tiling container holds exactly
    /// two children and no window ever gets thinner than half of its neighbour.
    case bsp
}

/// Which axis `bsp` splits along. Mirrors bspwm's `automatic_scheme`.
enum BspAutomaticScheme: String {
    /// Split the anchor's longer side. Keeps windows as close to square as the tree allows.
    case longestSide = "longest-side"
    /// Split along the axis opposite to the enclosing container, alternating with tree depth.
    case alternate
}

extension TreeNode {
    /// The axis `bsp` would cut `self` along to make room for one more window.
    @MainActor
    var bspSplitOrientation: Orientation {
        switch config.bspAutomaticScheme {
            case .longestSide:
                // `lastAppliedLayoutVirtualRect` is stamped during the previous layout pass, so it
                // describes where the node currently sits on screen. It is nil for nodes that were
                // never laid out (cold start, workspace restore), hence the fallback.
                if let rect = lastAppliedLayoutVirtualRect, rect.width > 0, rect.height > 0 {
                    return rect.width >= rect.height ? .h : .v
                }
                return alternatingSplitOrientation
            case .alternate:
                return alternatingSplitOrientation
        }
    }

    @MainActor
    private var alternatingSplitOrientation: Orientation {
        guard let parent = parent as? TilingContainer else {
            return (nodeMonitor.map { $0.width >= $0.height } ?? true) ? .h : .v
        }
        // A container holding a single child hasn't split anything yet, so its orientation is the axis
        // this split should use, not the one to alternate away from
        return parent.children.count > 1 ? parent.orientation.opposite : parent.orientation
    }
}

/// Takes over `anchor`'s slot in the tree with a fresh two-child container, and returns the
/// ``BindingData`` that the incoming window must be bound with to become `anchor`'s new sibling.
///
/// Unsafe on its own: it leaves `anchor` inside a container with a single child. The caller **must**
/// bind a node with the returned data.
///
/// - Parameters:
///   - orientation: the axis to split along. `nil` asks ``TreeNode/bspSplitOrientation`` to pick.
///   - insertBefore: `true` puts the incoming window above/left of `anchor` instead of below/right.
@MainActor
func bspSplit(anchor: TreeNode, orientation: Orientation? = nil, insertBefore: Bool = false) -> BindingData {
    let orientation = orientation ?? anchor.bspSplitOrientation
    let anchorBinding = anchor.unbindFromParent()
    let newParent = TilingContainer(
        parent: anchorBinding.parent,
        adaptiveWeight: anchorBinding.adaptiveWeight,
        orientation,
        .tiles,
        index: anchorBinding.index,
    )
    anchor.bind(to: newParent, adaptiveWeight: WEIGHT_AUTO, index: 0)
    return BindingData(
        parent: newParent,
        adaptiveWeight: WEIGHT_AUTO,
        index: insertBefore ? 0 : INDEX_BIND_LAST,
    )
}

/// Where a window should land when it enters `workspace`'s tiling tree without a direction in mind:
/// a newly detected window, a window that stopped being floating/minimized/fullscreen, or a window
/// moved to another workspace.
///
/// Unsafe: in `bsp` mode it already reshapes the tree (see ``bspSplit(anchor:orientation:insertBefore:)``),
/// so the caller **must** bind a node with the returned data. The window being inserted must be
/// unbound before calling, otherwise it can be picked as its own anchor.
@MainActor
func tilingInsertionPoint(in workspace: Workspace) -> BindingData {
    guard let anchor = workspace.mostRecentWindowRecursive,
          let tilingParent = anchor.parent as? TilingContainer,
          let anchorIndex = anchor.ownIndex
    else {
        // Nothing to anchor to. Note that reading `rootTilingContainer` creates it when missing
        return BindingData(parent: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    }

    return switch config.tilingInsertionMode {
        case .i3:
            BindingData(parent: tilingParent, adaptiveWeight: WEIGHT_AUTO, index: anchorIndex + 1)
        case .bsp:
            // An accordion is an explicit request to stack windows on top of each other. Splitting
            // it would silently undo that, so grow it like i3 does.
            tilingParent.layout == .accordion
                ? BindingData(parent: tilingParent, adaptiveWeight: WEIGHT_AUTO, index: anchorIndex + 1)
                : bspSplit(anchor: anchor)
    }
}

/// Moves `window` so that it ends up `direction`-ward of `anchor`, which is the node currently
/// occupying the space `window` is heading into. `anchor` may be a container, and `window` may be
/// somewhere inside it.
///
/// Unlike ``tilingInsertionPoint(in:)`` this one completes the move itself, because 'bsp' has
/// to take `window` out of the tree before it can reshape `anchor`'s slot, and a half-applied move
/// would leave `window` unbound.
///
/// Returns `false` without touching anything if `anchor` has no tiling parent to insert into.
@MainActor
func insertTilingWindow(_ window: Window, pushing anchor: TreeNode, _ direction: CardinalDirection) -> Bool {
    guard let parent = anchor.parent as? TilingContainer else { return false }
    window.unbindFromParent()
    switch config.tilingInsertionMode {
        case .i3:
            // `anchor` is still bound to `parent`, so it always has an index
            window.bind(to: parent, adaptiveWeight: WEIGHT_AUTO, index: anchor.ownIndex.orDie() + direction.insertionOffset)
        case .bsp:
            let binding = bspSplit(anchor: anchor, orientation: direction.orientation, insertBefore: !direction.isPositive)
            window.bindAsTilingWindow(at: binding)
    }
    return true
}

extension Window {
    /// Completes the "compute an insertion point, then bind" contract that the unsafe
    /// ``tilingInsertionPoint(in:)`` and ``bspSplit(anchor:orientation:insertBefore:)`` rely on.
    @MainActor
    func bindAsTilingWindow(at binding: BindingData) {
        bind(to: binding.parent, adaptiveWeight: binding.adaptiveWeight, index: binding.index)
    }
}
