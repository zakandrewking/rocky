import Foundation

/// One kind of durable character evidence supplied by literature. The labels are deliberately
/// concrete: a model can act on a remembered home or a particular dream; "whimsy 72%" only asks
/// it to decorate otherwise-generic assistant speech.
enum LiteraryDNASlot: String, CaseIterable, Codable, Sendable {
    case origin
    case physicalForm = "physical form"
    case childhood
    case drive
    case dream
    case voice
}

/// The same five-dimensional point edited by the existing sliders. Each quotation is a control
/// point in that space; the compiler selects the nearest quotation independently within every
/// identity slot. Keeping the source text itself as the character input is the experiment -- no
/// model-generated biography sits between the person's slider choice and the acting model.
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

    init(_ traits: PersonalityTraits) {
        self.init(
            warmth: traits.warmth,
            energy: traits.energy,
            humor: traits.humor,
            curiosity: traits.curiosity,
            talkativeness: traits.talkativeness
        )
    }

    func squaredDistance(to other: Self) -> Double {
        pow(warmth - other.warmth, 2)
            + pow(energy - other.energy, 2)
            + pow(humor - other.humor, 2)
            + pow(curiosity - other.curiosity, 2)
            + pow(talkativeness - other.talkativeness, 2)
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
    let coordinates: LiteraryCoordinates

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
    /// Physical-form passages describe materials, dimensionality, visibility, or constraints.
    /// The discarded "fat and bunchy" Velveteen Rabbit description does not belong here: body
    /// shape as a joke is neither necessary nor useful to the modern character this app wants.
    static let quotes: [LiteraryQuote] = [
        quote(
            "origin.wild-wood", .origin,
            "Beyond the Wild Wood comes the Wide World",
            "Kenneth Grahame", "The Wind in the Willows", 289,
            .init(warmth: 0.62, energy: 0.45, humor: 0.38, curiosity: 0.55, talkativeness: 0.24)
        ),
        quote(
            "origin.gray-prairie", .origin,
            "When Dorothy stood in the doorway and looked around, she could see nothing but the great gray prairie on every side.",
            "L. Frank Baum", "The Wonderful Wizard of Oz", 55,
            .init(warmth: 0.46, energy: 0.18, humor: 0.08, curiosity: 0.36, talkativeness: 0.54)
        ),
        quote(
            "origin.geneva", .origin,
            "I am by birth a Genevese, and my family is one of the most distinguished of that republic.",
            "Mary Shelley", "Frankenstein", 84,
            .init(warmth: 0.24, energy: 0.30, humor: 0.04, curiosity: 0.46, talkativeness: 0.62)
        ),
        quote(
            "origin.neverland", .origin,
            "Second to the right, and straight on till morning.",
            "J. M. Barrie", "Peter Pan", 16,
            .init(warmth: 0.50, energy: 0.92, humor: 0.68, curiosity: 0.82, talkativeness: 0.22)
        ),
        quote(
            "origin.flatland", .origin,
            "I call our world Flatland, not because we call it so, but to make its nature clearer to you, my happy readers, who are privileged to live in Space.",
            "Edwin A. Abbott", "Flatland", 201,
            .init(warmth: 0.42, energy: 0.38, humor: 0.50, curiosity: 0.78, talkativeness: 0.82)
        ),

        quote(
            "form.invisible", .physicalForm,
            "I'm an invisible man.",
            "H. G. Wells", "The Invisible Man", 5230,
            .init(warmth: 0.22, energy: 0.28, humor: 0.48, curiosity: 0.42, talkativeness: 0.12)
        ),
        quote(
            "form.tin", .physicalForm,
            "I am a Woodman, and made of tin.",
            "L. Frank Baum", "The Wonderful Wizard of Oz", 55,
            .init(warmth: 0.48, energy: 0.44, humor: 0.34, curiosity: 0.54, talkativeness: 0.20)
        ),
        quote(
            "form.living-wood", .physicalForm,
            "Once upon a time there was a piece of wood. It was not an expensive piece of wood. Far from it. Just a common block of firewood, one of those thick, solid logs that are put on the fire in winter to make cold rooms cozy and warm.",
            "Carlo Collodi", "The Adventures of Pinocchio", 500,
            .init(warmth: 0.64, energy: 0.70, humor: 0.72, curiosity: 0.76, talkativeness: 0.58)
        ),
        quote(
            "form.skeleton-leaves", .physicalForm,
            "He was a lovely boy, clad in skeleton leaves and the juices that ooze out of trees but the most entrancing thing about him was that he had all his first teeth.",
            "J. M. Barrie", "Peter Pan", 16,
            .init(warmth: 0.58, energy: 0.86, humor: 0.58, curiosity: 0.78, talkativeness: 0.50)
        ),
        quote(
            "form.assembled", .physicalForm,
            "His limbs were in proportion, and I had selected his features as beautiful.",
            "Mary Shelley", "Frankenstein", 84,
            .init(warmth: 0.16, energy: 0.52, humor: 0.02, curiosity: 0.84, talkativeness: 0.70)
        ),

        quote(
            "childhood.asylum", .childhood,
            "I've never belonged to anybody—not really. But the asylum was the worst.",
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
            "My mother's tender caresses and my father's smile of benevolent pleasure while regarding me are my first recollections.",
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
            "It's been my experience that you can nearly always enjoy things if you make up your mind firmly that you will.",
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
            "dream.splendid", .dream,
            "I want to do something splendid before I go into my castle, something heroic or wonderful that won't be forgotten after I'm dead.",
            "Louisa May Alcott", "Little Women", 514,
            .init(warmth: 0.54, energy: 0.84, humor: 0.28, curiosity: 0.70, talkativeness: 0.64)
        ),
        quote(
            "dream.discoveries", .dream,
            "I shall find out thousands and thousands of things. I shall find out about people and creatures and everything that grows—like Dickon—and I shall never stop making Magic.",
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
            "voice.truth", .voice,
            "The truth is rarely pure and never simple.",
            "Oscar Wilde", "The Importance of Being Earnest", 844,
            .init(warmth: 0.28, energy: 0.52, humor: 1.00, curiosity: 0.68, talkativeness: 0.30)
        ),
        quote(
            "voice.observe", .voice,
            "You see, but you do not observe. The distinction is clear.",
            "Arthur Conan Doyle", "The Adventures of Sherlock Holmes", 1661,
            .init(warmth: 0.22, energy: 0.38, humor: 0.30, curiosity: 1.00, talkativeness: 0.18)
        ),
        quote(
            "voice.boats", .voice,
            "Nothing seems really to matter, that's the charm of it. Whether you get away, or whether you don't; whether you arrive at your destination or whether you reach somewhere else, or whether you never get anywhere at all, you're always busy, and you never do anything in particular; and when you've done it there's always something else to do, and you can do it if you like, but you'd much better not.",
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
        let target = LiteraryCoordinates(traits)
        let selected = LiteraryDNASlot.allCases.compactMap { slot in
            quotes
                .filter { $0.slot == slot }
                .min { lhs, rhs in
                    let left = lhs.coordinates.squaredDistance(to: target)
                    let right = rhs.coordinates.squaredDistance(to: target)
                    if left == right { return lhs.id < rhs.id }
                    return left < right
                }
        }
        return LiteraryDNA(quotes: selected)
    }

    private static func quote(
        _ id: String,
        _ slot: LiteraryDNASlot,
        _ text: String,
        _ author: String,
        _ work: String,
        _ ebook: Int,
        _ coordinates: LiteraryCoordinates
    ) -> LiteraryQuote {
        LiteraryQuote(
            id: id,
            slot: slot,
            text: text,
            author: author,
            work: work,
            source: "https://www.gutenberg.org/ebooks/\(ebook)",
            coordinates: coordinates
        )
    }
}
