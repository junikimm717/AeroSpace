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

    func testMoveAcrossTheEdgeOfASameOrientationContainer() async {
        // h_tiles[w1, h_tiles[w2, w3]]: w2 is a quarter of the screen next to the half-screen w1. Splitting
        // w2's own container would be undone by normalization, so the move must cross into w1 instead
        let workspace = Workspace.get(byName: name).apply {
            $0.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0)
                TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).apply {
                    assertEquals(TestWindow.new(id: 2, parent: $0).focusWindow(), true)
                    TestWindow.new(id: 3, parent: $0)
                }
            }
        }

        await parseCommand("move left").cmdOrDie.run(.defaultEnv, .emptyStdin)
        workspace.normalizeContainers()
        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([.h_tiles([.window(1), .window(2)]), .window(3)]),
        )

        // And from there an ordinary swap
        await parseCommand("move left").cmdOrDie.run(.defaultEnv, .emptyStdin)
        workspace.normalizeContainers()
        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([.h_tiles([.window(2), .window(1)]), .window(3)]),
        )
    }

    func testMoveIntoTheWorkspaceEdgeIsANoop() async {
        // h_tiles[w1, v_tiles[w2, w3]]: w2 already touches the top of the screen. bspwm does nothing here,
        // whereas the implicit container would stretch w2 across the whole top and push w3 next to w1
        let workspace = Workspace.get(byName: name).apply {
            $0.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0)
                TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                    assertEquals(TestWindow.new(id: 2, parent: $0).focusWindow(), true)
                    TestWindow.new(id: 3, parent: $0)
                }
            }
        }
        let before = workspace.rootTilingContainer.layoutDescription

        await parseCommand("move up").cmdOrDie.run(.defaultEnv, .emptyStdin)
        workspace.normalizeContainers()
        assertEquals(workspace.rootTilingContainer.layoutDescription, before)

        // Pressing towards the sibling still swaps
        await parseCommand("move down").cmdOrDie.run(.defaultEnv, .emptyStdin)
        workspace.normalizeContainers()
        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([.window(1), .v_tiles([.window(3), .window(2)])]),
        )
    }

    func testExplicitBoundariesActionStillCreatesTheImplicitContainer() async {
        // h_tiles[w1, h_tiles[w2, w3]]: nothing is right of w3
        let workspace = Workspace.get(byName: name).apply {
            $0.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0)
                TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).apply {
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

        await parseCommand("move --boundaries-action create-implicit-container right").cmdOrDie.run(.defaultEnv, .emptyStdin)
        workspace.normalizeContainers()
        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([.h_tiles([.window(1), .window(2)]), .window(3)]),
        )
    }

    func testSwapIsBspwmNodeSwap() async {
        // h_tiles[w1, h_tiles[w2, w3]]: the bspwm way to put the small w2 where the big w1 is
        let workspace = Workspace.get(byName: name).apply {
            $0.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0)
                TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).apply {
                    assertEquals(TestWindow.new(id: 2, parent: $0).focusWindow(), true)
                    TestWindow.new(id: 3, parent: $0)
                }
            }
        }

        await parseCommand("swap left").cmdOrDie.run(.defaultEnv, .emptyStdin)
        workspace.normalizeContainers()
        assertEquals( // Same shape, w1 and w2 traded places, focus stayed on w2
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([.window(2), .h_tiles([.window(1), .window(3)])]),
        )
        assertEquals(focus.windowOrNil?.windowId, 2)

        await parseCommand("swap left").cmdOrDie.run(.defaultEnv, .emptyStdin) // Screen edge
        workspace.normalizeContainers()
        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([.window(2), .h_tiles([.window(1), .window(3)])]),
        )
    }

    func testAccordionIsAWholeWorkspaceMonocle() async throws {
        // h_tiles[w1, h_tiles[w2, w3]] with w3 focused: 'layout v_accordion' would only stack w2 and w3 in i3
        // terms. bspwm's monocle covers the whole desktop and keeps the tree for when it's turned off
        let workspace = Workspace.get(byName: name).apply {
            $0.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0)
                TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).apply {
                    TestWindow.new(id: 2, parent: $0)
                    assertEquals(TestWindow.new(id: 3, parent: $0).focusWindow(), true)
                }
            }
        }
        let tree = workspace.rootTilingContainer.layoutDescription
        let windows = workspace.rootTilingContainer.allLeafWindowsRecursive

        await parseCommand("layout v_accordion").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(workspace.isMonocle, true)
        assertEquals(workspace.rootTilingContainer.layoutDescription, tree)
        try await workspace.layoutWorkspace()
        let fullRect = workspace.lastAppliedLayoutPhysicalRect.orDie()
        for window in windows { // All stacked over the whole workspace
            assertEquals(window.lastAppliedLayoutPhysicalRect?.width, fullRect.width)
            assertEquals(window.lastAppliedLayoutPhysicalRect?.topLeftX, fullRect.topLeftX)
        }

        await parseCommand("layout tiles").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(workspace.isMonocle, false)
        try await workspace.layoutWorkspace()
        assertEquals(workspace.rootTilingContainer.layoutDescription, tree)
        let w1 = windows[0].lastAppliedLayoutPhysicalRect.orDie().width
        let w2 = windows[1].lastAppliedLayoutPhysicalRect.orDie().width
        assertTrue(w1 > 1.5 * w2) // Back to half / quarter / quarter

        await parseCommand("layout tiles accordion").cmdOrDie.run(.defaultEnv, .emptyStdin) // Toggles
        assertEquals(workspace.isMonocle, true)
        await parseCommand("layout tiles accordion").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(workspace.isMonocle, false)
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
