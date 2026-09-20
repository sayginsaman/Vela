import XCTest
@testable import Vela

final class SceneArrangementTests: XCTestCase {
    private let wide = CGSize(width: 2000, height: 1130)

    // MARK: Layout

    func testSplitCompositionIsCentredOnAWideWindow() {
        let layout = StageLayout(size: wide, split: true)
        XCTAssertTrue(layout.isSplit)
        XCTAssertEqual(layout.contentWidth, layout.panelWidth + layout.gap + layout.lyricWidth, accuracy: 0.001)
        // The columns take the middle of the window, with matching space on both sides.
        let trailingInset = wide.width - layout.leadingInset - layout.contentWidth
        XCTAssertEqual(layout.leadingInset, trailingInset, accuracy: 0.001)
        XCTAssertGreaterThan(layout.leadingInset, 100, "A 2000pt window should not run the columns to its edges.")
    }

    func testLyricColumnStopsGrowingWithTheWindow() {
        let layout = StageLayout(size: CGSize(width: 3400, height: 1400), split: true)
        XCTAssertEqual(layout.lyricWidth, StageLayout.maximumLyricWidth, accuracy: 0.001)
        XCTAssertLessThanOrEqual(layout.panelWidth, StageLayout.naturalPanelWidth.upperBound)
    }

    func testNarrowWindowFallsBackToTheCentredStage() {
        let layout = StageLayout(size: CGSize(width: 700, height: 900), split: true)
        XCTAssertFalse(layout.isSplit)
        XCTAssertEqual(layout.panelWidth, 0)
        XCTAssertEqual(layout.lyricWidth, 700)
        XCTAssertEqual(layout.leadingInset, 0)
        XCTAssertEqual(layout.alignment, .center)
    }

    func testResizingAnElementKeepsTheGroupCentred() {
        let bigger = SceneArrangement(scale: 1.4, offsetX: 0, offsetY: 0)
        let plain = StageLayout(size: wide, split: true)
        let scaled = StageLayout(size: wide, split: true, panel: bigger)
        XCTAssertEqual(scaled.panelWidth, plain.panelWidth * 1.4, accuracy: 0.001)
        XCTAssertLessThan(scaled.leadingInset, plain.leadingInset, "A wider panel eats into the side margin.")
        let trailingInset = wide.width - scaled.leadingInset - scaled.contentWidth
        XCTAssertEqual(scaled.leadingInset, trailingInset, accuracy: 0.001)
    }

    func testColumnsNeverOverflowTheWindow() {
        let huge = SceneArrangement(scale: SceneArrangement.scaleRange.upperBound)
        let layout = StageLayout(size: CGSize(width: 900, height: 700), split: true, lyric: huge, panel: huge)
        XCTAssertLessThanOrEqual(layout.contentWidth, 900, "The columns must stay inside the window.")
        XCTAssertGreaterThan(layout.lyricWidth, 0)
    }

    func testSplitTextIsSizedFromItsOwnColumn() {
        let split = StageLayout(size: wide, split: true)
        let centred = StageLayout(size: wide, split: false)
        XCTAssertLessThan(split.typographyBase, centred.typographyBase)
        XCTAssertGreaterThan(split.typographyBase, 30, "The split column should still carry a large word.")
    }

    // MARK: Arrangement values

    func testClampingKeepsElementsReachable() {
        let wild = SceneArrangement(scale: 9, offsetX: -4, offsetY: 3).clamped()
        XCTAssertEqual(wild.scale, SceneArrangement.scaleRange.upperBound)
        XCTAssertEqual(wild.offsetX, SceneArrangement.offsetRange.lowerBound)
        XCTAssertEqual(wild.offsetY, SceneArrangement.offsetRange.upperBound)
    }

    func testTranslationIsAShareOfTheStage() {
        let arrangement = SceneArrangement(scale: 1, offsetX: 0.1, offsetY: -0.25)
        let translation = arrangement.translation(in: CGSize(width: 1000, height: 800))
        XCTAssertEqual(translation.width, 100, accuracy: 0.001)
        XCTAssertEqual(translation.height, -200, accuracy: 0.001)
    }

    func testIdentityIsTheUntouchedComposition() {
        XCTAssertTrue(SceneArrangement.identity.isIdentity)
        XCTAssertFalse(SceneArrangement(scale: 1.1).isIdentity)
    }

    // MARK: Settings

    func testArrangementSurvivesASaveAndIsNormalisedOnLoad() throws {
        var settings = VelaSettings()
        settings.lyricArrangement = SceneArrangement(scale: 1.2, offsetX: 0.08, offsetY: -0.05)
        settings.panelArrangement = SceneArrangement(scale: 3, offsetX: 0, offsetY: 0)
        let data = try JSONEncoder().encode(settings)
        let loaded = try JSONDecoder().decode(VelaSettings.self, from: data).normalized()
        XCTAssertEqual(loaded.lyricArrangement, settings.lyricArrangement)
        XCTAssertEqual(loaded.panelArrangement.scale, SceneArrangement.scaleRange.upperBound,
                       "An out-of-range scale must be brought back into reach on load.")
    }

    func testSettingsFromBeforeThisFeatureLoadUntouched() throws {
        let json = Data(#"{"lyricSize": 1.0, "localAlignment": false}"#.utf8)
        let loaded = try JSONDecoder().decode(VelaSettings.self, from: json)
        XCTAssertTrue(loaded.lyricArrangement.isIdentity)
        XCTAssertTrue(loaded.panelArrangement.isIdentity)
    }

    @MainActor
    func testArrangingLeavesSettingsAndResetRestoresTheComposition() {
        let model = AppModel(settingsStore: SettingsStore(defaults: UserDefaults(suiteName: "vela.arrange.tests")!))
        model.settingsVisible = true
        model.beginArrangingScene()
        XCTAssertTrue(model.isArrangingScene)
        XCTAssertFalse(model.settingsVisible, "Arranging happens on the scene, so Settings gets out of the way.")

        model.settings.lyricArrangement = SceneArrangement(scale: 1.3, offsetX: 0.2, offsetY: 0.1)
        model.resetArrangement()
        XCTAssertTrue(model.settings.lyricArrangement.isIdentity)
        XCTAssertTrue(model.settings.panelArrangement.isIdentity)

        model.endArrangingScene()
        XCTAssertFalse(model.isArrangingScene)
    }
}
