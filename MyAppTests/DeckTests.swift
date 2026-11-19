import Foundation
import Testing
@testable import Immich_Swipe_iOS

struct DeckTests {
    private func asset(_ id: String, size: Int64? = nil) -> Asset {
        Asset(id: id, ownerId: "u", fileCreatedAt: "2024", type: .image, exifInfo: size.map { ExifInfo(fileSizeInByte: $0) })
    }

    private func pile(_ ids: String...) -> [Asset] { ids.map { asset($0) } }

    @Test func startsAtFirstUndecidedAsset() {
        let deck = Deck(assets: pile("a", "b", "c"), decisions: ["a": .keep])
        #expect(deck.current?.id == "b")
    }

    @Test func decidingAdvancesPastAlreadyDecidedCards() {
        var deck = Deck(assets: pile("a", "b", "c", "d"), decisions: ["b": .keep, "c": .delete])
        deck.decideCurrent(.archive)
        #expect(deck.current?.id == "d")
        #expect(deck.decision(for: "a") == .archive)
    }

    @Test func finishesAfterTheLastCard() {
        var deck = Deck(assets: pile("a", "b"))
        deck.decideCurrent(.keep)
        deck.decideCurrent(.delete)
        #expect(deck.isFinished)
        #expect(deck.current == nil)
        #expect(deck.decideCurrent(.keep) == nil)
    }

    @Test func wrapsAroundToCardsThatSortedInBehindTheCurrentOne() {
        var deck = Deck(assets: pile("b", "c"))
        deck.decideCurrent(.keep) // b, now on c
        // A later page brings "a", which sorts ahead of the current card.
        deck.replaceAssets(pile("a", "b", "c"), keepPosition: true)
        #expect(deck.current?.id == "c")
        deck.decideCurrent(.keep)
        #expect(deck.current?.id == "a")
        deck.decideCurrent(.keep)
        #expect(deck.isFinished)
    }

    @Test func emptyDeckIsNotFinished() {
        #expect(!Deck().isFinished)
    }

    @Test func undoReturnsToTheUndoneCard() {
        var deck = Deck(assets: pile("a", "b", "c"))
        deck.decideCurrent(.keep)
        deck.decideCurrent(.delete)
        #expect(deck.undo() == "b")
        #expect(deck.current?.id == "b")
        #expect(deck.decision(for: "b") == nil)
        #expect(deck.undo() == "a")
        #expect(deck.current?.id == "a")
        #expect(!deck.canUndo)
        #expect(deck.undo() == nil)
    }

    @Test func undoWorksFromTheFinishedState() {
        var deck = Deck(assets: pile("a"))
        deck.decideCurrent(.delete)
        #expect(deck.isFinished)
        deck.undo()
        #expect(deck.current?.id == "a")
    }

    @Test func upcomingSkipsDecidedCards() {
        let deck = Deck(assets: pile("a", "b", "c", "d", "e"), decisions: ["c": .keep])
        #expect(deck.upcoming(2).map(\.id) == ["b", "d"])
    }

    @Test func bulkDecisionContinuesAfterTheLastSelected() {
        var deck = Deck(assets: pile("a", "b", "c", "d", "e"))
        deck.decide(.delete, assetIDs: ["a", "c"])
        #expect(deck.current?.id == "d")
        #expect(deck.count(of: .delete) == 2)
        #expect(deck.undo() == "c")
    }

    @Test func newPageKeepsTheCurrentCardOnScreen() {
        var deck = Deck(assets: pile("a", "b", "c"))
        deck.decideCurrent(.keep) // now on b
        deck.replaceAssets(pile("x", "a", "b", "c", "y"), keepPosition: true)
        #expect(deck.current?.id == "b")
    }

    @Test func resortJumpsToFirstUndecided() {
        var deck = Deck(assets: pile("a", "b", "c"))
        deck.decideCurrent(.keep)
        deck.decideCurrent(.keep) // now on c
        deck.replaceAssets(pile("c", "b", "a", "z"), keepPosition: false)
        #expect(deck.current?.id == "c")
        deck.decideCurrent(.keep)
        #expect(deck.current?.id == "z")
    }

    @Test func storedDecisionsMergeWithoutOverridingSessionOnes() {
        var deck = Deck(assets: pile("a", "b", "c"))
        deck.decideCurrent(.delete) // a
        deck.mergeStoredDecisions(["a": .keep, "b": .archive], unsyncedHistory: ["b"])
        #expect(deck.decision(for: "a") == .delete)
        #expect(deck.decision(for: "b") == .archive)
        #expect(deck.current?.id == "c")
        // Stored unsynced decisions come first in the undo order, session ones last.
        #expect(deck.undo() == "a")
        #expect(deck.undo() == "b")
    }

    @Test func removingADecisionBehindTheCurrentCardRevisitsIt() {
        var deck = Deck(assets: pile("a", "b", "c"))
        deck.decideCurrent(.keep)
        deck.decideCurrent(.keep) // now on c
        deck.removeDecision(for: "a")
        #expect(deck.current?.id == "a")
        #expect(deck.history == ["b"])
    }

    @Test func removingAssetsAfterApplyKeepsPosition() {
        var deck = Deck(assets: pile("a", "b", "c", "d"))
        deck.decideCurrent(.delete) // a
        deck.decideCurrent(.keep)   // b, now on c
        deck.removeAssets(["a"])
        #expect(deck.assets.map(\.id) == ["b", "c", "d"])
        #expect(deck.current?.id == "c")
        #expect(deck.decision(for: "a") == nil)
        #expect(deck.history == ["b"])
    }

    @Test func countsAndBytesOnlyIncludeAssetsInThePile() {
        let assets = [asset("a", size: 100), asset("b", size: 50), asset("c")]
        let deck = Deck(assets: assets, decisions: ["a": .delete, "b": .delete, "c": .delete, "gone": .delete])
        #expect(deck.bytes(of: .delete) == 150)
        #expect(deck.decidedCount == 3)
        #expect(deck.count(of: .delete) == 4)
    }

    @Test func resetForgetsEverything() {
        var deck = Deck(assets: pile("a", "b"))
        deck.decideCurrent(.keep)
        deck.reset()
        #expect(deck.current?.id == "a")
        #expect(!deck.canUndo)
        #expect(deck.decidedCount == 0)
    }

    /// The running counts must always equal a count of the pile done from scratch.
    @Test func runningCountsMatchARecountAfterEveryChange() {
        func expectCountsMatch(_ deck: Deck, _ step: String) {
            let decided = deck.assets.compactMap { deck.decision(for: $0.id) }
            #expect(deck.decidedCount == decided.count, "\(step)")
            for decision in SwipeDecision.allCases {
                #expect(deck.pileCount(of: [decision]) == decided.count { $0 == decision }, "\(step): \(decision)")
            }
            #expect(deck.pileCount(of: [.keep, .delete]) == decided.count { $0 == .keep || $0 == .delete }, "\(step): keep and delete")
        }

        // "x" is decided but not in the pile, so it's never counted.
        var deck = Deck(assets: pile("a", "b", "c", "d", "e"), decisions: ["b": .keep, "x": .delete])
        expectCountsMatch(deck, "init")
        deck.decideCurrent(.delete) // a
        expectCountsMatch(deck, "decide")
        deck.move(to: 0)
        deck.decideCurrent(.archive) // a again, replacing delete
        expectCountsMatch(deck, "re-decide")
        deck.decide(.lock, assetIDs: ["c", "d", "x"])
        expectCountsMatch(deck, "bulk")
        deck.undo() // x, not in the pile
        expectCountsMatch(deck, "undo outside the pile")
        deck.undo() // d
        expectCountsMatch(deck, "undo")
        deck.removeDecision(for: "b")
        expectCountsMatch(deck, "remove decision")
        // "c" leaves the pile and comes back; "f" arrives with a stored decision.
        deck.replaceAssets(pile("a", "b", "d", "e", "f"), keepPosition: true)
        expectCountsMatch(deck, "replace, dropping c")
        deck.mergeStoredDecisions(["f": .keep, "c": .delete], unsyncedHistory: [])
        expectCountsMatch(deck, "merge")
        deck.replaceAssets(pile("a", "b", "c", "d", "e", "f"), keepPosition: true)
        expectCountsMatch(deck, "replace, c back")
        deck.removeAssets(["a", "f"])
        expectCountsMatch(deck, "remove assets")
        deck.reset()
        expectCountsMatch(deck, "reset")
    }
}
