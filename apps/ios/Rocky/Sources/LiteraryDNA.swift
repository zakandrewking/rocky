import Foundation

/// One kind of durable character evidence supplied by literature. The labels are deliberately
/// concrete: a model can act on a remembered home or a particular dream; "whimsy 72%" only asks
/// it to decorate otherwise-generic assistant speech.
enum LiteraryDNASlot: String, CaseIterable, Codable, Sendable {
    case origin
    case physicalForm = "physical form"
    case childhood
    case drive
    case comicLens = "comic lens"
    case dream
    case voice

    var sliderName: String {
        switch self {
        case .origin: "fantasy ↔ reality"
        case .physicalForm: "earth ↔ sky"
        case .childhood: "warmth"
        case .drive: "energy"
        case .comicLens: "humor"
        case .dream: "curiosity"
        case .voice: "talkativeness"
        }
    }
}

/// Source-corpus metadata retained in its compact five-axis form. Selection is intentionally
/// one-dimensional: each slot reads exactly one matching slider, so moving warmth cannot silently
/// replace origin, form, dream, and voice at the same time.
struct LiteraryCoordinates: Equatable, Sendable {
    let warmth: Double
    let energy: Double
    let humor: Double
    let curiosity: Double
    let talkativeness: Double

    init(
        warmth: Double,
        energy: Double,
        humor: Double,
        curiosity: Double,
        talkativeness: Double
    ) {
        self.warmth = warmth
        self.energy = energy
        self.humor = humor
        self.curiosity = curiosity
        self.talkativeness = talkativeness
    }

    func value(for slot: LiteraryDNASlot) -> Double {
        switch slot {
        case .childhood: warmth
        case .drive: energy
        case .comicLens: humor
        case .dream: curiosity
        case .voice: talkativeness
        case .origin, .physicalForm: 0.5
        }
    }
}

struct LiteraryQuote: Identifiable, Equatable, Sendable {
    let id: String
    let slot: LiteraryDNASlot
    /// Verbatim words from the linked edition, with only ebook typography normalised.
    let text: String
    let author: String
    let work: String
    let source: String
    /// Position on the one slider assigned to this quote's slot.
    let axisPosition: Double

    var sourceURL: URL? { URL(string: source) }
}

struct LiteraryDNA: Equatable, Sendable {
    let quotes: [LiteraryQuote]

    subscript(slot: LiteraryDNASlot) -> LiteraryQuote? {
        quotes.first { $0.slot == slot }
    }
}

enum LiteraryQuoteCatalog {
    /// A deliberately small probe corpus, not yet a production library. Every entry links to the
    /// exact Project Gutenberg edition it was checked against, which marks the text public domain
    /// in the USA. Modern translations and random quotation sites are intentionally absent.
    ///
    /// Every slot is controlled by exactly one slider. Physical form runs from small earth creature
    /// to large creature to space-being; origin runs from fantasy to reality. The discarded "fat
    /// and bunchy" Velveteen Rabbit description is intentionally absent.
    static let quotes: [LiteraryQuote] = [
        quote(
            "origin.wild-wood", .origin,
            "Beyond the Wild Wood comes the Wide World",
            "Kenneth Grahame", "The Wind in the Willows", 289,
            .init(warmth: 0.62, energy: 0.45, humor: 0.38, curiosity: 0.55, talkativeness: 0.24), 0.50
        ),
        quote(
            "origin.gray-prairie", .origin,
            "When Dorothy stood in the doorway and looked around, she could see nothing but the great gray prairie on every side.",
            "L. Frank Baum", "The Wonderful Wizard of Oz", 55,
            .init(warmth: 0.46, energy: 0.18, humor: 0.08, curiosity: 0.36, talkativeness: 0.54), 0.75
        ),
        quote(
            "origin.geneva", .origin,
            "I am by birth a Genevese, and my family is one of the most distinguished of that republic.",
            "Mary Shelley", "Frankenstein", 84,
            .init(warmth: 0.24, energy: 0.30, humor: 0.04, curiosity: 0.46, talkativeness: 0.62), 1.00
        ),
        quote(
            "origin.neverland", .origin,
            "Second to the right, and straight on till morning.",
            "J. M. Barrie", "Peter Pan", 16,
            .init(warmth: 0.50, energy: 0.92, humor: 0.68, curiosity: 0.82, talkativeness: 0.22), 0.00
        ),
        quote(
            "origin.flatland", .origin,
            "I call our world Flatland, not because we call it so, but to make its nature clearer to you, my happy readers, who are privileged to live in Space.",
            "Edwin A. Abbott", "Flatland", 201,
            .init(warmth: 0.42, energy: 0.38, humor: 0.50, curiosity: 0.78, talkativeness: 0.82), 0.25
        ),

        quote(
            "form.mole", .physicalForm,
            "The Mole had been working very hard all the morning, spring-cleaning his little home.",
            "Kenneth Grahame", "The Wind in the Willows", 289,
            .init(warmth: 0.60, energy: 0.35, humor: 0.40, curiosity: 0.45, talkativeness: 0.30), 0.00
        ),
        quote(
            "form.white-rabbit", .physicalForm,
            "a White Rabbit with pink eyes ran close by her",
            "Lewis Carroll", "Alice's Adventures in Wonderland", 11,
            .init(warmth: 0.45, energy: 0.75, humor: 0.65, curiosity: 0.70, talkativeness: 0.30), 0.25
        ),
        quote(
            "form.lion", .physicalForm,
            "the next moment a great Lion bounded into the road.",
            "L. Frank Baum", "The Wonderful Wizard of Oz", 55,
            .init(warmth: 0.45, energy: 0.80, humor: 0.25, curiosity: 0.45, talkativeness: 0.35), 0.50
        ),
        quote(
            "form.thark", .physicalForm,
            "The man himself, for such I may call him, was fully fifteen feet in height and, on Earth, would have weighed some four hundred pounds.",
            "Edgar Rice Burroughs", "A Princess of Mars", 62,
            .init(warmth: 0.20, energy: 0.75, humor: 0.10, curiosity: 0.65, talkativeness: 0.45), 0.75
        ),
        quote(
            "form.martian", .physicalForm,
            "Two large dark-coloured eyes were regarding me steadfastly. The mass that framed them, the head of the thing, was rounded, and had, one might say, a face.",
            "H. G. Wells", "The War of the Worlds", 36,
            .init(warmth: 0.10, energy: 0.40, humor: 0.05, curiosity: 0.85, talkativeness: 0.30), 1.00
        ),

        quote(
            "childhood.asylum", .childhood,
            "I’ve never belonged to anybody--not really. But the asylum was the worst.",
            "L. M. Montgomery", "Anne of Green Gables", 45,
            .init(warmth: 0.86, energy: 0.52, humor: 0.18, curiosity: 0.72, talkativeness: 0.66)
        ),
        quote(
            "childhood.discord", .childhood,
            "I was a discord in Gateshead Hall: I was like nobody there; I had nothing in harmony with Mrs. Reed or her children, or her chosen vassalage.",
            "Charlotte Brontë", "Jane Eyre", 1260,
            .init(warmth: 0.18, energy: 0.28, humor: 0.08, curiosity: 0.54, talkativeness: 0.44)
        ),
        quote(
            "childhood.ran-away", .childhood,
            "Wendy, I ran away the day I was born.",
            "J. M. Barrie", "Peter Pan", 16,
            .init(warmth: 0.38, energy: 0.96, humor: 0.62, curiosity: 0.44, talkativeness: 0.34)
        ),
        quote(
            "childhood.idol", .childhood,
            "My mother’s tender caresses and my father’s smile of benevolent pleasure while regarding me are my first recollections.",
            "Mary Shelley", "Frankenstein", 84,
            .init(warmth: 0.92, energy: 0.28, humor: 0.04, curiosity: 0.42, talkativeness: 0.76)
        ),
        quote(
            "childhood.princess", .childhood,
            "I pretend I am a princess, so that I can try and behave like one.",
            "Frances Hodgson Burnett", "A Little Princess", 146,
            .init(warmth: 0.74, energy: 0.34, humor: 0.28, curiosity: 0.62, talkativeness: 0.40)
        ),

        quote(
            "drive.remote", .drive,
            "I am tormented with an everlasting itch for things remote.",
            "Herman Melville", "Moby-Dick", 2701,
            .init(warmth: 0.34, energy: 0.76, humor: 0.18, curiosity: 0.98, talkativeness: 0.38)
        ),
        quote(
            "drive.free", .drive,
            "I am no bird; and no net ensnares me; I am a free human being with an independent will, which I now exert to leave you.",
            "Charlotte Brontë", "Jane Eyre", 1260,
            .init(warmth: 0.38, energy: 0.66, humor: 0.06, curiosity: 0.58, talkativeness: 0.46)
        ),
        quote(
            "drive.data", .drive,
            "It is a capital mistake to theorise before one has data.",
            "Arthur Conan Doyle", "The Adventures of Sherlock Holmes", 1661,
            .init(warmth: 0.24, energy: 0.48, humor: 0.20, curiosity: 0.98, talkativeness: 0.22)
        ),
        quote(
            "drive.enjoy", .drive,
            "It’s been my experience that you can nearly always enjoy things if you make up your mind firmly that you will.",
            "L. M. Montgomery", "Anne of Green Gables", 45,
            .init(warmth: 0.88, energy: 0.54, humor: 0.38, curiosity: 0.78, talkativeness: 0.74)
        ),
        quote(
            "drive.adventure", .drive,
            "Take the Adventure, heed the call, now ere the irrevocable moment passes!",
            "Kenneth Grahame", "The Wind in the Willows", 289,
            .init(warmth: 0.58, energy: 0.98, humor: 0.54, curiosity: 0.82, talkativeness: 0.56)
        ),

        quote(
            "comic.forgive", .comicLens,
            "Life appears to me too short to be spent in nursing animosity or registering wrongs.",
            "Charlotte Brontë", "Jane Eyre", 1260,
            .init(warmth: 0.74, energy: 0.30, humor: 0.00, curiosity: 0.50, talkativeness: 0.55)
        ),
        quote(
            "comic.obvious", .comicLens,
            "There is nothing more deceptive than an obvious fact",
            "Arthur Conan Doyle", "The Adventures of Sherlock Holmes", 1661,
            .init(warmth: 0.25, energy: 0.35, humor: 0.25, curiosity: 0.85, talkativeness: 0.25)
        ),
        quote(
            "comic.moonshine", .comicLens,
            "Well, moonshine is a brighter thing than fog",
            "Arthur Conan Doyle", "The Adventures of Sherlock Holmes", 1661,
            .init(warmth: 0.45, energy: 0.50, humor: 0.50, curiosity: 0.65, talkativeness: 0.35)
        ),
        quote(
            "comic.truth", .comicLens,
            "The truth is rarely pure and never simple.",
            "Oscar Wilde", "The Importance of Being Earnest", 844,
            .init(warmth: 0.30, energy: 0.55, humor: 0.75, curiosity: 0.65, talkativeness: 0.35)
        ),
        quote(
            "comic.diary", .comicLens,
            "I never travel without my diary. One should always have something sensational to read in the train.",
            "Oscar Wilde", "The Importance of Being Earnest", 844,
            .init(warmth: 0.40, energy: 0.65, humor: 1.00, curiosity: 0.60, talkativeness: 0.65)
        ),

        quote(
            "dream.splendid", .dream,
            "I want to do something splendid before I go into my castle, something heroic or wonderful that won’t be forgotten after I’m dead.",
            "Louisa May Alcott", "Little Women", 514,
            .init(warmth: 0.54, energy: 0.84, humor: 0.28, curiosity: 0.70, talkativeness: 0.64)
        ),
        quote(
            "dream.discoveries", .dream,
            "I shall find out thousands and thousands of things. I shall find out about people and creatures and everything that grows--like Dickon--and I shall never stop making Magic.",
            "Frances Hodgson Burnett", "The Secret Garden", 17396,
            .init(warmth: 0.72, energy: 0.76, humor: 0.24, curiosity: 1.00, talkativeness: 0.76)
        ),
        quote(
            "dream.heart", .dream,
            "And I am going to ask him to give me a heart",
            "L. Frank Baum", "The Wonderful Wizard of Oz", 55,
            .init(warmth: 0.98, energy: 0.42, humor: 0.10, curiosity: 0.52, talkativeness: 0.26)
        ),
        quote(
            "dream.real", .dream,
            "He longed to become Real, to know what it felt like; and yet the idea of growing shabby and losing his eyes and whiskers was rather sad.",
            "Margery Williams", "The Velveteen Rabbit", 11757,
            .init(warmth: 0.92, energy: 0.32, humor: 0.06, curiosity: 0.66, talkativeness: 0.44)
        ),
        quote(
            "dream.puffed-sleeves", .dream,
            "It would give me such a thrill, Marilla, just to wear a dress with puffed sleeves.",
            "L. M. Montgomery", "Anne of Green Gables", 45,
            .init(warmth: 0.68, energy: 0.64, humor: 0.64, curiosity: 0.54, talkativeness: 0.62)
        ),

        quote(
            "voice.curiouser", .voice,
            "Curiouser and curiouser!",
            "Lewis Carroll", "Alice's Adventures in Wonderland", 11,
            .init(warmth: 0.58, energy: 0.88, humor: 0.76, curiosity: 0.94, talkativeness: 0.08)
        ),
        quote(
            "voice.opinion", .voice,
            "My good opinion once lost is lost for ever.",
            "Jane Austen", "Pride and Prejudice", 1342,
            .init(warmth: 0.28, energy: 0.52, humor: 0.45, curiosity: 0.55, talkativeness: 0.30)
        ),
        quote(
            "voice.observe", .voice,
            "You see, but you do not observe. The distinction is clear.",
            "Arthur Conan Doyle", "The Adventures of Sherlock Holmes", 1661,
            .init(warmth: 0.22, energy: 0.38, humor: 0.30, curiosity: 1.00, talkativeness: 0.18)
        ),
        quote(
            "voice.boats", .voice,
            "Nothing seems really to matter, that’s the charm of it. Whether you get away, or whether you don’t; whether you arrive at your destination or whether you reach somewhere else, or whether you never get anywhere at all, you’re always busy, and you never do anything in particular; and when you’ve done it there’s always something else to do, and you can do it if you like, but you’d much better not.",
            "Kenneth Grahame", "The Wind in the Willows", 289,
            .init(warmth: 0.72, energy: 0.52, humor: 0.56, curiosity: 0.68, talkativeness: 1.00)
        ),
        quote(
            "voice.stubborn", .voice,
            "There is a stubbornness about me that never can bear to be frightened at the will of others.",
            "Jane Austen", "Pride and Prejudice", 1342,
            .init(warmth: 0.24, energy: 0.72, humor: 0.58, curiosity: 0.48, talkativeness: 0.56)
        ),
    ]

    static func selection(for traits: PersonalityTraits) -> LiteraryDNA {
        let selected = LiteraryDNASlot.allCases.compactMap { slot in
            let target = targetValue(for: slot, traits: traits)
            return quotes
                .filter { $0.slot == slot }
                .min { lhs, rhs in
                    let left = abs(lhs.axisPosition - target)
                    let right = abs(rhs.axisPosition - target)
                    if left == right { return lhs.id < rhs.id }
                    return left < right
                }
        }
        return LiteraryDNA(quotes: selected)
    }

    private static func targetValue(for slot: LiteraryDNASlot, traits: PersonalityTraits) -> Double {
        switch slot {
        case .origin: traits.fantasyToReality
        case .physicalForm: traits.earthToSky
        case .childhood: traits.warmth
        case .drive: traits.energy
        case .comicLens: traits.humor
        case .dream: traits.curiosity
        case .voice: traits.talkativeness
        }
    }

    private static func quote(
        _ id: String,
        _ slot: LiteraryDNASlot,
        _ text: String,
        _ author: String,
        _ work: String,
        _ ebook: Int,
        _ coordinates: LiteraryCoordinates,
        _ axisPosition: Double? = nil
    ) -> LiteraryQuote {
        LiteraryQuote(
            id: id,
            slot: slot,
            text: text,
            author: author,
            work: work,
            source: "https://www.gutenberg.org/ebooks/\(ebook)",
            axisPosition: axisPosition ?? coordinates.value(for: slot)
        )
    }
}
