import Foundation

/// Demo-mode audio: runs a `ProfileFixture` through the real `FeatureExtractor` at a fixed
/// rate so Demo Mode exercises exactly the pipeline captured audio uses.
struct DemoFeatureProducer: Sendable {
    private(set) var fixture: ProfileFixture
    private var extractor = FeatureExtractor()

    init(fixture: ProfileFixture) {
        self.fixture = fixture
    }

    mutating func setFixture(_ newFixture: ProfileFixture) {
        guard newFixture != fixture else { return }
        fixture = newFixture
        extractor.reset()
    }

    mutating func reset() { extractor.reset() }

    mutating func produce(position: TimeInterval, playing: Bool) -> MusicFeatureSnapshot {
        extractor.ingest(fixture.descriptor(at: position, playing: playing))
    }
}
