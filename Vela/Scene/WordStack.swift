import SwiftUI

/// A sung word with its position in the document, addressed by a flat index.
struct FlatWord: Identifiable, Hashable, Sendable {
    var id: Int
    var sungLine: Int
    var wordIndex: Int
    var word: TimedWord
}

/// Pure layout maths for the word stack, kept separate so it can be tested.
enum WordStackLayout {
    static func medianDuration(of words: [TimedWord]) -> TimeInterval {
        let durations = words.map(\.duration).filter { $0 > 0.02 }.sorted()
        guard !durations.isEmpty else { return 0.4 }
        return durations[durations.count / 2]
    }

    /// Held words grow, quick words stay compact: 1 at the median, capped both ways.
    static func sizeFactor(duration: TimeInterval, median: TimeInterval) -> Double {
        let m = max(0.05, median)
        let ratio = max(0.05, duration) / m
        return min(1.6, max(0.82, 1 + 0.38 * log2(ratio)))
    }

    /// Which flat word the stack should centre on, and whether that word is being sung now.
    static func anchor(position: LyricPosition, box: LyricTimelineBox) -> (index: Int, isCurrent: Bool) {
        guard !box.flatWords.isEmpty else { return (0, false) }
        guard let documentLine = position.lineIndex, let sungLine = box.sungIndex(forDocumentLine: documentLine) else {
            return (0, false)
        }
        if position.isInBreak {
            let next = box.firstFlatIndex(ofSungLine: sungLine + 1) ?? (box.flatWords.count - 1)
            return (next, false)
        }
        if let wordIndex = position.wordIndex, let flat = box.flatIndex(sungLine: sungLine, word: wordIndex) {
            return (flat, true)
        }
        return (box.firstFlatIndex(ofSungLine: sungLine) ?? 0, false)
    }
}

/// Word-stack stage: one word per row, the sung word large in the middle with a filled tag that
/// reveals with the word's progress, past words receding above, upcoming words waiting below.
/// The column advances word by word, so its pace is the song's pace.
struct WordStackStageView: View {
    let box: LyricTimelineBox
    let typography: LyricTypography
    let clock: PlaybackClock
    let offset: TimeInterval
    let director: VisualDirector
    let showIcons: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !clock.isRunning && !director.isPreviewing)) { context in
            let time = clock.position(at: context.date) + offset
            let position = box.locate(at: time)
            let motion = director.lyricSnapshot()
            var live = typography
            let _ = {
                live.motion = motion.style
                live.beatImpulse = (motion.beatImpulse * 50).rounded() / 50
                live.beatCount = motion.beatCount
            }()
            let anchor = WordStackLayout.anchor(position: position, box: box)
            WordStackColumn(words: box.flatWords,
                            anchor: anchor.index,
                            anchorIsCurrent: anchor.isCurrent,
                            progress: position.wordProgress,
                            typography: live,
                            medianDuration: box.medianWordDuration,
                            showBreathing: position.isInBreak,
                            countdown: position.timeUntilNextLine,
                            showIcons: showIcons)
        }
    }
}

private struct WordStackColumn: View {
    let words: [FlatWord]
    let anchor: Int
    let anchorIsCurrent: Bool
    let progress: Double
    let typography: LyricTypography
    let medianDuration: TimeInterval
    let showBreathing: Bool
    let countdown: TimeInterval?
    let showIcons: Bool

    private let before = 2
    private let after = 2
    private var spacing: CGFloat { typography.fontSize * 0.5 }

    /// Row heights follow the font sizes directly, so the layout never lags a frame behind a
    /// role change (measured heights would, and rows would briefly overlap).
    private func height(of index: Int) -> CGFloat {
        let size = StackWordView.fontSize(for: role(for: index), base: typography.fontSize,
                                          sizeFactor: WordStackLayout.sizeFactor(duration: words[index].word.duration, median: medianDuration))
        return size * 1.22
    }

    private func offset(for index: Int) -> CGFloat {
        if index == anchor { return 0 }
        var value = height(of: anchor) / 2 + spacing
        if index < anchor {
            for k in (index + 1)..<anchor { value += height(of: k) + spacing }
            return -(value + height(of: index) / 2)
        } else {
            for k in (anchor + 1)..<index { value += height(of: k) + spacing }
            return value + height(of: index) / 2
        }
    }

    private func role(for index: Int) -> StackRole {
        if index < anchor { return .past }
        if index == anchor { return anchorIsCurrent ? .current : .upcoming }
        return .upcoming
    }

    var body: some View {
        GeometryReader { proxy in
            let lower = max(0, anchor - before)
            let upper = min(words.count - 1, anchor + after)
            ZStack(alignment: typography.alignment.stackAlignment) {
                if lower <= upper {
                    // Identity is the word itself, so rows keep their view as the window slides.
                    ForEach(words[lower...upper]) { flat in
                        let index = flat.id
                        let distance = index - anchor
                        StackWordView(word: words[index].word,
                                      role: role(for: index),
                                      distance: distance,
                                      progress: index == anchor ? progress : 0,
                                      typography: index == anchor ? typography : typography.still,
                                      sizeFactor: WordStackLayout.sizeFactor(duration: words[index].word.duration, median: medianDuration),
                                      maxWidth: proxy.size.width * (typography.alignment == .leading ? 0.98 : 0.88),
                                      showIcon: showIcons)
                            .offset(y: offset(for: index))
                            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: typography.reduceMotion ? 0 : 28)),
                                                    removal: .opacity.combined(with: .offset(y: typography.reduceMotion ? 0 : -28))))
                    }
                }
                if showBreathing {
                    BreathingIndicator(countdown: countdown, color: typography.palette.highlight.swiftUIColor,
                                       reduceMotion: typography.reduceMotion, size: typography.fontSize * 0.2)
                        .offset(y: -(height(of: anchor) / 2 + spacing + typography.fontSize * 0.9))
                        .transition(.opacity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .animation(typography.motion.lineAnimation, value: anchor)
            .animation(.easeInOut(duration: 0.3), value: showBreathing)
        }
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(anchorIsCurrent && anchor < words.count ? "Current word: \(words[anchor].word.text)" : "Lyrics")
    }
}

enum StackRole { case past, current, upcoming }

/// One row of the stack.
private struct StackWordView: View {
    let word: TimedWord
    let role: StackRole
    let distance: Int
    let progress: Double
    let typography: LyricTypography
    let sizeFactor: Double
    let maxWidth: CGFloat
    let showIcon: Bool

    static func fontSize(for role: StackRole, base: CGFloat, sizeFactor: Double) -> CGFloat {
        switch role {
        case .current: return base * 2.3 * CGFloat(sizeFactor)
        case .past: return base * 1.0
        case .upcoming: return base * 1.1
        }
    }

    private var fontSize: CGFloat { Self.fontSize(for: role, base: typography.fontSize, sizeFactor: sizeFactor) }

    private var opacity: Double {
        let d = Double(abs(distance))
        switch role {
        case .current: return 1
        case .past: return max(0.14, (typography.increaseContrast ? 0.6 : 0.4) - 0.14 * (d - 1))
        case .upcoming: return max(0.16, (typography.increaseContrast ? 0.62 : 0.42) - 0.12 * (d - 1))
        }
    }

    private var font: Font {
        let design: Font.Design
        switch typography.motion.typeface {
        case .sans: design = .default
        case .serif: design = .serif
        case .rounded: design = .rounded
        }
        var f = Font.system(size: fontSize, weight: role == .current ? .heavy : .bold, design: design)
        if role == .past { f = f.italic() }
        return f
    }

    private var tilt: Double {
        guard !typography.reduceMotion else { return 0 }
        // A slight, deterministic lean per word so the tag never sits perfectly square.
        return word.id.isMultiple(of: 2) ? -2.4 : 2.0
    }

    private var iconName: String? { showIcon ? WordIconMap.symbol(for: word.text) : nil }

    var body: some View {
        let text = Text(word.text).font(font).kerning(-fontSize * 0.02)
        HStack(spacing: fontSize * 0.28) {
            ZStack(alignment: .leading) {
                text.foregroundStyle(typography.primaryColor)
                if role == .current {
                    tagLayer(text: text)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.35)
            // Font changes between roles swap instantly; only position, scale and opacity animate,
            // otherwise SwiftUI crossfades a ghost of the word at its previous size.
            .transaction { $0.animation = nil }
            if let iconName {
                Image(systemName: iconName)
                    .font(.system(size: fontSize * 0.62, weight: .semibold))
                    .foregroundStyle(role == .current ? typography.palette.highlight.swiftUIColor : typography.primaryColor)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: maxWidth, alignment: typography.alignment.frameAlignment)
        .opacity(opacity)
        .blur(radius: typography.reduceEffects || role == .current ? 0 : CGFloat(abs(distance)) * 0.8)
        .scaleEffect(role == .current && !typography.reduceMotion ? 1 + 0.03 * typography.beatImpulse : 1)
        .animation(typography.motion.wordAnimation, value: role == .current)
        .animation(.easeOut(duration: 0.2), value: iconName)
    }

    /// Filled tag in the highlight colour that reveals left-to-right with the word's progress; the
    /// letters over it flip to the background colour so the fill reads as a sweep.
    private func tagLayer(text: Text) -> some View {
        let insetX = fontSize * 0.14
        let insetY = fontSize * 0.02
        let fill = min(1, max(0, progress))
        // The dark text sizes the layer; the tag hangs off it as a background so it hugs the word.
        return text.foregroundStyle(typography.palette.background.swiftUIColor)
            .background {
                RoundedRectangle(cornerRadius: fontSize * 0.1, style: .continuous)
                    .fill(typography.palette.highlight.swiftUIColor)
                    .padding(.horizontal, -insetX)
                    .padding(.vertical, -insetY)
                    .rotationEffect(.degrees(tilt))
            }
            .mask(alignment: .leading) {
                GeometryReader { proxy in
                    Rectangle()
                        .frame(width: insetX * 2.5 + (proxy.size.width + insetX * 1.5) * fill,
                               height: proxy.size.height + fontSize * 0.4)
                        .offset(x: -insetX * 2.5, y: -fontSize * 0.2)
                }
            }
            .shadow(color: typography.palette.highlight.swiftUIColor.opacity(typography.reduceEffects ? 0 : 0.5 * typography.motion.activeWordBloom + 0.15),
                    radius: fontSize * 0.3)
    }
}


/// Words that have a matching symbol, shown beside them in the Stack style. Lookup is on the
/// lower-cased word with punctuation removed.
enum WordIconMap {
    static func symbol(for word: String) -> String? {
        let key = word.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !key.isEmpty else { return nil }
        if let hit = table[key] { return hit }
        // Simple plural / possessive fallbacks.
        if key.hasSuffix("s"), let hit = table[String(key.dropLast())] { return hit }
        if key.hasSuffix("ing"), let hit = table[String(key.dropLast(3))] { return hit }
        return nil
    }

    static let table: [String: String] = [
        "heart": "heart.fill", "love": "heart.fill", "loved": "heart.fill", "lover": "heart.fill", "hearts": "heart.fill",
        "star": "star.fill", "stars": "star.fill", "moon": "moon.fill", "sun": "sun.max.fill", "sunshine": "sun.max.fill",
        "sky": "cloud.sun.fill", "cloud": "cloud.fill", "rain": "cloud.rain.fill", "storm": "cloud.bolt.rain.fill", "thunder": "cloud.bolt.fill",
        "lightning": "bolt.fill", "snow": "snowflake", "wind": "wind", "fire": "flame.fill", "flame": "flame.fill",
        "burn": "flame.fill", "fuego": "flame.fill", "ice": "snowflake", "cold": "thermometer.snowflake", "hot": "thermometer.sun.fill",
        "heat": "thermometer.sun.fill", "water": "drop.fill", "ocean": "water.waves", "sea": "water.waves", "wave": "hand.wave.fill",
        "tide": "water.waves", "river": "water.waves", "drop": "drop.fill", "night": "moon.stars.fill", "midnight": "moon.stars.fill",
        "morning": "sunrise.fill", "sunrise": "sunrise.fill", "sunset": "sunset.fill", "dawn": "sunrise.fill", "day": "sun.max.fill",
        "light": "lightbulb.fill", "lights": "lightbulb.fill", "lamp": "lamp.desk.fill", "candle": "flame", "dark": "moon.fill",
        "shadow": "moon.haze.fill", "phone": "phone.fill", "call": "phone.fill", "calling": "phone.fill", "ring": "phone.fill",
        "text": "message.fill", "message": "message.fill", "talk": "bubble.left.fill", "talking": "bubble.left.fill", "say": "bubble.left.fill",
        "said": "bubble.left.fill", "tell": "bubble.left.fill", "telling": "bubble.left.fill", "speak": "bubble.left.fill", "sing": "music.mic",
        "singing": "music.mic", "song": "music.note", "music": "music.note", "radio": "radio.fill", "beat": "metronome.fill",
        "drum": "music.quarternote.3", "guitar": "guitars.fill", "piano": "pianokeys", "bass": "speaker.wave.3.fill", "loud": "speaker.wave.3.fill",
        "quiet": "speaker.slash.fill", "silence": "speaker.slash.fill", "sound": "speaker.wave.2.fill", "car": "car.fill", "cars": "car.fill",
        "drive": "car.fill", "driving": "car.fill", "road": "road.lanes", "street": "road.lanes", "highway": "road.lanes",
        "train": "tram.fill", "plane": "airplane", "fly": "bird.fill", "flying": "airplane", "bus": "bus.fill",
        "bike": "bicycle", "boat": "sailboat.fill", "ship": "ferry.fill", "rocket": "paperplane.fill", "map": "map.fill",
        "home": "house.fill", "house": "house.fill", "door": "door.left.hand.open", "window": "window.casement", "windows": "window.casement",
        "city": "building.2.fill", "town": "building.2.fill", "building": "building.fill", "kitchen": "refrigerator.fill", "bed": "bed.double.fill",
        "sleep": "bed.double.fill", "dream": "sparkles", "dreams": "sparkles", "magic": "sparkles", "shine": "sparkles",
        "money": "dollarsign.circle.fill", "cash": "banknote.fill", "gold": "crown.fill", "rich": "dollarsign.circle.fill", "pay": "creditcard.fill",
        "diamond": "diamond.fill", "crown": "crown.fill", "king": "crown.fill", "queen": "crown.fill", "time": "clock.fill",
        "clock": "clock.fill", "minute": "clock.fill", "hour": "clock.fill", "wait": "hourglass", "waiting": "hourglass",
        "late": "clock.badge.exclamationmark.fill", "forever": "infinity", "always": "infinity", "never": "nosign", "eye": "eye.fill",
        "eyes": "eye.fill", "see": "eye.fill", "look": "eye.fill", "watch": "applewatch", "blind": "eye.slash.fill",
        "hand": "hand.raised.fill", "hands": "hand.raised.fill", "point": "hand.point.up.left.fill", "walk": "figure.walk", "walking": "figure.walk",
        "run": "figure.run", "running": "figure.run", "dance": "figure.dance", "dancing": "figure.dance", "baila": "figure.dance",
        "jump": "figure.jumprope", "fight": "figure.boxing", "you": "person.fill", "me": "person.fill", "girl": "person.fill",
        "boy": "person.fill", "friend": "person.2.fill", "friends": "person.2.fill", "people": "person.3.fill", "everybody": "person.3.fill",
        "family": "person.3.fill", "baby": "figure.and.child.holdinghands", "mama": "figure.and.child.holdinghands", "mother": "figure.and.child.holdinghands", "ball": "basketball.fill",
        "ballin": "basketball.fill", "basketball": "basketball.fill", "game": "gamecontroller.fill", "play": "play.fill", "stop": "stop.fill",
        "pause": "pause.fill", "swish": "basketball.fill", "goal": "soccerball", "number": "number", "numbers": "number",
        "one": "1.circle.fill", "two": "2.circle.fill", "three": "3.circle.fill", "ten": "10.circle.fill", "hundred": "100.circle.fill",
        "million": "dollarsign.circle.fill", "zero": "0.circle.fill", "key": "key.fill", "keys": "key.fill", "lock": "lock.fill",
        "locked": "lock.fill", "open": "lock.open.fill", "chain": "link", "gun": "scope", "shoot": "scope",
        "shot": "scope", "bomb": "burst.fill", "knife": "scissors", "sword": "shield.fill", "war": "shield.fill",
        "shield": "shield.fill", "book": "book.fill", "page": "doc.fill", "write": "pencil", "wrote": "pencil",
        "pen": "pencil", "letter": "envelope.fill", "mail": "envelope.fill", "photo": "photo.fill", "picture": "photo.fill",
        "camera": "camera.fill", "movie": "film.fill", "tv": "tv.fill", "screen": "tv.fill", "mirror": "rectangle.portrait.fill",
        "glass": "wineglass.fill", "wine": "wineglass.fill", "drink": "wineglass.fill", "coffee": "cup.and.saucer.fill", "cup": "cup.and.saucer.fill",
        "kettle": "cup.and.saucer.fill", "bread": "birthday.cake.fill", "cake": "birthday.cake.fill", "birthday": "birthday.cake.fill", "party": "party.popper.fill",
        "gift": "gift.fill", "present": "gift.fill", "flower": "leaf.fill", "flowers": "leaf.fill", "rose": "leaf.fill",
        "tree": "tree.fill", "trees": "tree.fill", "branch": "leaf.fill", "leaf": "leaf.fill", "garden": "leaf.fill",
        "orchard": "tree.fill", "grass": "leaf.fill", "mountain": "mountain.2.fill", "hill": "mountain.2.fill", "beach": "beach.umbrella.fill",
        "sand": "beach.umbrella.fill", "island": "beach.umbrella.fill", "world": "globe.americas.fill", "earth": "globe.americas.fill", "planet": "globe.americas.fill",
        "space": "sparkles", "universe": "sparkles", "heaven": "cloud.sun.fill", "angel": "sparkles", "devil": "flame.fill",
        "smile": "face.smiling.fill", "laugh": "face.smiling.fill", "laughing": "face.smiling.fill", "happy": "face.smiling.fill", "cry": "drop.fill",
        "tears": "drop.fill", "sad": "cloud.rain.fill", "pain": "bandage.fill", "hurt": "bandage.fill", "broken": "heart.slash.fill",
        "break": "heart.slash.fill", "kiss": "heart.fill", "hug": "heart.circle.fill", "wire": "cable.connector", "signal": "antenna.radiowaves.left.and.right",
        "static": "waveform", "button": "button.programmable", "push": "hand.point.up.left.fill", "switch": "switch.2", "engine": "engine.combustion.fill",
        "heater": "thermometer.sun.fill", "lantern": "lamp.floor.fill", "lanterns": "lamp.floor.fill", "concrete": "square.fill",
        "shirt": "tshirt.fill", "shoes": "shoe.fill", "shoe": "shoe.fill", "hat": "graduationcap.fill",
        "coat": "tshirt.fill", "bag": "bag.fill", "pocket": "bag.fill", "pockets": "bag.fill", "glasses": "eyeglasses",
        "name": "person.text.rectangle.fill", "sign": "signpost.right.fill", "signs": "signpost.right.fill", "way": "arrow.triangle.turn.up.right.diamond.fill", "up": "arrow.up",
        "down": "arrow.down", "left": "arrow.left", "right": "arrow.right", "back": "arrow.uturn.backward", "go": "arrow.right.circle.fill",
        "come": "arrow.left.circle.fill", "stay": "pin.fill", "leave": "arrow.right.square.fill", "fast": "hare.fill", "slow": "tortoise.fill",
        "speed": "speedometer", "lento": "tortoise.fill", "bird": "bird.fill", "dog": "dog.fill", "cat": "cat.fill",
        "wolf": "pawprint.fill", "lion": "pawprint.fill", "fish": "fish.fill", "horse": "hare.fill", "bee": "ant.fill",
        "butterfly": "leaf.fill", "kite": "wind", "kites": "wind", "doctor": "cross.case.fill", "medicine": "pills.fill",
        "pill": "pills.fill", "hospital": "cross.fill", "school": "graduationcap.fill", "church": "building.columns.fill", "prayer": "hands.sparkles.fill",
        "pray": "hands.sparkles.fill", "god": "sparkles", "soul": "sparkles", "spirit": "sparkles", "ghost": "moon.haze.fill",
        "yes": "checkmark.circle.fill", "no": "xmark.circle.fill", "okay": "checkmark.circle.fill", "ok": "checkmark.circle.fill", "question": "questionmark.circle.fill",
        "why": "questionmark.circle.fill", "secret": "eye.slash.fill", "hide": "eye.slash.fill", "search": "magnifyingglass", "find": "magnifyingglass",
        "found": "magnifyingglass", "lost": "questionmark.circle.fill", "power": "bolt.fill", "energy": "bolt.fill", "electric": "bolt.fill",
        "neon": "lightbulb.max.fill", "glow": "lightbulb.max.fill", "spark": "sparkle", "sparkle": "sparkle", "bloom": "sparkles",
        "flash": "bolt.fill",
    ]
}
