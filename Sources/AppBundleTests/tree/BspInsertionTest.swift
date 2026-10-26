@testable import AppBundle
import Common
import XCTest

@MainActor
final class BspInsertionTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        // Mirror what parseConfig pins for 'bsp'
        config.tilingInsertionMode = .bsp
        config.enableNormalizationFlattenContainers = true
        config.enableNormalizationOppositeOrientationForNestedContainers = false
    }

    func testFirstWindowLandsInTheRootContainer() {
        let workspace = Workspace.get(byName: name)
        insertWindow(1, into: workspace)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1)]))
    }

    func testSecondWindowSplitsTheFirstAlongItsLongestSide() {
        let workspace = Workspace.get(byName: name)
        let w1 = insertWindow(1, into: workspace)
        w1.lastAppliedLayoutVirtualRect = testRect(width: 1600, height: 900) // Wide -> cut vertically
        insertWindow(2, into: workspace)
        workspace.normalizeContainers()
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(2)]))
    }

    func testThirdWindowSplitsTheTallHalfTheOtherWay() {
        let workspace = Workspace.get(byName: name)
        let w1 = insertWindow(1, into: workspace)
        w1.lastAppliedLayoutVirtualRect = testRect(width: 1600, height: 900)
        let w2 = insertWindow(2, into: workspace)
        workspace.normalizeContainers()
        // w2 now owns the right half, which is taller than it is wide
        w2.lastAppliedLayoutVirtualRect = testRect(width: 800, height: 900)
        insertWindow(3, into: workspace)
        workspace.normalizeContainers()
        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([.window(1), .v_tiles([.window(2), .window(3)])]),
        )
    }

    func testSplitsAreFiftyFifty() {
        let workspace = Workspace.get(byName: name)
        let w1 = insertWindow(1, into: workspace)
        w1.lastAppliedLayoutVirtualRect = testRect(width: 1600, height: 900)
        let w2 = insertWindow(2, into: workspace)
        workspace.normalizeContainers()
        assertEquals(w1.getWeight(.h), w2.getWeight(.h))
    }

    func testNoContainerEverHoldsMoreThanTwoChildren() {
        let workspace = Workspace.get(byName: name)
        for id in 1 ... 8 {
            insertWindow(UInt32(id), into: workspace)
            workspace.normalizeContainers()
            assertEquals(containerArities(workspace.rootTilingContainer).filter { $0 > 2 }, [])
        }
        assertEquals(
            workspace.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId).sorted(),
            (1 ... 8).map(UInt32.init),
        )
    }

    func testAlternateSchemeIgnoresGeometry() {
        config.bspAutomaticScheme = .alternate
        let workspace = Workspace.get(byName: name)
        let w1 = insertWindow(1, into: workspace)
        w1.lastAppliedLayoutVirtualRect = testRect(width: 1600, height: 900) // Deliberately wide
        let w2 = insertWindow(2, into: workspace)
        workspace.normalizeContainers()
        w2.lastAppliedLayoutVirtualRect = testRect(width: 1600, height: 900) // Deliberately wide again
        insertWindow(3, into: workspace)
        workspace.normalizeContainers()
        // The root is horizontal, so depth 1 must be vertical no matter how wide w2 looked
        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([.window(1), .v_tiles([.window(2), .window(3)])]),
        )
    }

    func testLongestSideFallsBackToAlternatingWhenGeometryIsUnknown() {
        let workspace = Workspace.get(byName: name)
        insertWindow(1, into: workspace) // No layout pass ever ran, so there is no rect to measure
        insertWindow(2, into: workspace)
        workspace.normalizeContainers()
        insertWindow(3, into: workspace)
        workspace.normalizeContainers()
        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([.window(1), .v_tiles([.window(2), .window(3)])]),
        )
    }

    func testI3ModeKeepsAppendingSiblings() {
        config.tilingInsertionMode = .i3
        config.enableNormalizationFlattenContainers = false
        let workspace = Workspace.get(byName: name)
        for id in 1 ... 3 { insertWindow(UInt32(id), into: workspace) }
        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([.window(1), .window(2), .window(3)]),
        )
    }

    func testMoveOutReparentsInsteadOfWideningTheContainer() async {
        // h_tiles[w1, v_tiles[w2, w3]]. Moving w3 right must not turn the root into a 3-window row
        let workspace = Workspace.get(byName: name).apply {
            $0.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0)
                TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                    TestWindow.new(id: 2, parent: $0)
                    assertEquals(TestWindow.new(id: 3, parent: $0).focusWindow(), true)
                }
            }
        }

        await parseCommand("move right").cmdOrDie.run(.defaultEnv, .emptyStdin)
        workspace.normalizeContainers()

        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([.window(1), .h_tiles([.window(2), .window(3)])]),
        )
        assertEquals(containerArities(workspace.rootTilingContainer).filter { $0 > 2 }, [])
    }

    func testMoveIntoASiblingContainerSplitsTheLeafFocusWouldHaveLandedOn() async {
        // h_tiles[w1, v_tiles[w2, w3]]. The stack is vertical while the move is horizontal, so there
        // is no single "left edge" leaf, and the move follows 'focus right' and picks the stack's MRU
        let workspace = Workspace.get(byName: name).apply {
            $0.rootTilingContainer.apply {
                let w1 = TestWindow.new(id: 1, parent: $0)
                TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                    TestWindow.new(id: 2, parent: $0)
                    assertEquals(TestWindow.new(id: 3, parent: $0).focusWindow(), true) // MRU of the stack
                }
                assertEquals(w1.focusWindow(), true)
            }
        }

        await parseCommand("move right").cmdOrDie.run(.defaultEnv, .emptyStdin)
        workspace.normalizeContainers()

        // w1 splits w3 and takes the left half of it
        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .v_tiles([.window(2), .h_tiles([.window(1), .window(3)])]),
        )
        assertEquals(containerArities(workspace.rootTilingContainer).filter { $0 > 2 }, [])
    }

    func testFlattenWorkspaceTreeRebuildsABalancedTree() async {
        let workspace = Workspace.get(byName: name).apply {
            $0.rootTilingContainer.apply { // A degenerate right-leaning chain, the worst case for bsp
                TestWindow.new(id: 1, parent: $0)
                TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                    TestWindow.new(id: 2, parent: $0)
                    TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).apply {
                        TestWindow.new(id: 3, parent: $0)
                        TestWindow.new(id: 4, parent: $0)
                    }
                }
            }
        }
        assertEquals(workspace.focusWorkspace(), true)

        await parseCommand("flatten-workspace-tree").cmdOrDie.run(.defaultEnv, .emptyStdin)
        workspace.normalizeContainers()

        // The exact orientations depend on the monitor's aspect ratio, but the shape must be a
        // perfectly balanced binary tree: 3 containers of 2 children each over 4 windows
        assertEquals(containerArities(workspace.rootTilingContainer), [2, 2, 2])
        assertEquals(
            workspace.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId).sorted(),
            [1, 2, 3, 4],
        )
    }

    func testClosingAWindowCollapsesItsContainer() {
        let workspace = Workspace.get(byName: name)
        insertWindow(1, into: workspace)
        let w2 = insertWindow(2, into: workspace)
        workspace.normalizeContainers()
        let w3 = insertWindow(3, into: workspace)
        workspace.normalizeContainers()
        w3.unbindFromParent()
        workspace.normalizeContainers()
        // w2 is back to owning the whole half that it shared with w3
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(2)]))
        assertTrue(w2.parent === workspace.rootTilingContainer)
    }
}

@MainActor
@discardableResult
private func insertWindow(_ id: UInt32, into workspace: Workspace) -> TestWindow {
    let binding = tilingInsertionPoint(in: workspace)
    let window = TestWindow.new(id: id, parent: binding.parent)
    window.bind(to: binding.parent, adaptiveWeight: binding.adaptiveWeight, index: binding.index)
    return window
}

private func testRect(width: CGFloat, height: CGFloat) -> Rect {
    Rect(topLeftX: 0, topLeftY: 0, width: width, height: height)
}

@MainActor
private func containerArities(_ node: TreeNode) -> [Int] {
    var result: [Int] = []
    if node is TilingContainer { result.append(node.children.count) }
    for child in node.children { result += containerArities(child) }
    return result
}
