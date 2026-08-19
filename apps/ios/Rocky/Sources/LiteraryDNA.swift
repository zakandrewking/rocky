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
            "origin.caverns", .origin,
            "These mountains were full of hollow places underneath; huge caverns, and winding ways, some with water running through them, and some shining with all colours of the rainbow when a light was taken in.",
            "George MacDonald", "The Princess and the Goblin", 708,
            .init(warmth: 0.48, energy: 0.46, humor: 0.12, curiosity: 0.92, talkativeness: 0.58), 0.00
        ),
        quote(
            "origin.white-house", .origin,
            "The White House was on the edge of a hill, with a wood behind it--and the chalk-quarry on one side and the gravel-pit on the other.",
            "E. Nesbit", "Five Children and It", 778,
            .init(warmth: 0.62, energy: 0.52, humor: 0.48, curiosity: 0.78, talkativeness: 0.48), 0.25
        ),
        quote(
            "origin.flatland", .origin,
            "I call our world Flatland, not because we call it so, but to make its nature clearer to you, my happy readers, who are privileged to live in Space.",
            "Edwin A. Abbott", "Flatland", 201,
            .init(warmth: 0.42, energy: 0.38, humor: 0.50, curiosity: 0.78, talkativeness: 0.82), 0.50
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
            "form.sand-fairy", .physicalForm,
            "the spider-shaped brown hairy body, long arms and legs, bat’s ears and snail’s eyes of the Sand-fairy himself.",
            "E. Nesbit", "Five Children and It", 778,
            .init(warmth: 0.44, energy: 0.36, humor: 0.76, curiosity: 0.84, talkativeness: 0.48), 0.00
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
            "childhood.stolen-knife", .childhood,
            "Injun Joe sprang to his feet, his eyes flaming with passion, snatched up Potter’s knife, and went creeping, catlike and stooping, round and round about the combatants, seeking an opportunity.",
            "Mark Twain", "The Adventures of Tom Sawyer", 74,
            .init(warmth: 0.00, energy: 0.78, humor: 0.00, curiosity: 0.48, talkativeness: 0.44), 0.00
        ),
        quote(
            "childhood.fire", .childhood,
            "In my joy I thrust my hand into the live embers, but quickly drew it out again with a cry of pain. How strange, I thought, that the same cause should produce such opposite effects!",
            "Mary Shelley", "Frankenstein", 84,
            .init(warmth: 0.25, energy: 0.58, humor: 0.00, curiosity: 0.90, talkativeness: 0.56), 0.25
        ),
        quote(
            "childhood.wincey", .childhood,
            "A merchant in Hopeton last winter donated three hundred yards of wincey to the asylum. Some people said it was because he couldn’t sell it, but I’d rather believe that it was out of the kindness of his heart, wouldn’t you?",
            "L. M. Montgomery", "Anne of Green Gables", 45,
            .init(warmth: 0.50, energy: 0.42, humor: 0.42, curiosity: 0.62, talkativeness: 0.84), 0.50
        ),
        quote(
            "childhood.shining-waters", .childhood,
            "That’s Barry’s pond. Oh, I don’t like that name, either. I shall call it--let me see--the Lake of Shining Waters. Yes, that is the right name for it. I know because of the thrill.",
            "L. M. Montgomery", "Anne of Green Gables", 45,
            .init(warmth: 0.75, energy: 0.62, humor: 0.46, curiosity: 0.82, talkativeness: 0.78), 0.75
        ),
        quote(
            "childhood.christmas-breakfast", .childhood,
            "Six children are huddled into one bed to keep from freezing, for they have no fire. There is nothing to eat over there, and the oldest boy came to tell me they were suffering hunger and cold. My girls, will you give them your breakfast as a Christmas present?",
            "Louisa May Alcott", "Little Women", 514,
            .init(warmth: 1.00, energy: 0.64, humor: 0.06, curiosity: 0.42, talkativeness: 0.60), 1.00
        ),

        quote(
            "drive.spring-cleaning", .drive,
            "The Mole had been working very hard all the morning, spring-cleaning his little home.",
            "Kenneth Grahame", "The Wind in the Willows", 289,
            .init(warmth: 0.60, energy: 0.00, humor: 0.40, curiosity: 0.45, talkativeness: 0.30), 0.00
        ),
        quote(
            "drive.sold-piano", .drive,
            "Then he sold his piano, and let the mice live in a bureau-drawer. But the money he got for that too began to go, so he sold the brown suit he wore on Sundays and went on becoming poorer and poorer.",
            "Hugh Lofting", "The Story of Doctor Dolittle", 501,
            .init(warmth: 0.82, energy: 0.25, humor: 0.54, curiosity: 0.54, talkativeness: 0.48), 0.25
        ),
        quote(
            "drive.twenty-five-dollars", .drive,
            "My dear, where did you get it? Twenty-five dollars! Jo, I hope you haven’t done anything rash? No, it’s mine honestly. I didn’t beg, borrow, or steal it. I earned it, and I don’t think you’ll blame me, for I only sold what was my own.",
            "Louisa May Alcott", "Little Women", 514,
            .init(warmth: 0.78, energy: 0.50, humor: 0.18, curiosity: 0.48, talkativeness: 0.60), 0.50
        ),
        quote(
            "drive.tin-kitchen", .drive,
            "As long as The Spread Eagle paid her a dollar a column for her ‘rubbish,’ as she called it, Jo felt herself a woman of means, and spun her little romances diligently. But great plans fermented in her busy brain and ambitious mind, and the old tin kitchen in the garret held a slowly increasing pile of blotted manuscript.",
            "Louisa May Alcott", "Little Women", 514,
            .init(warmth: 0.52, energy: 0.75, humor: 0.34, curiosity: 0.86, talkativeness: 0.66), 0.75
        ),
        quote(
            "drive.eight-feet", .drive,
            "I resolved, contrary to my first intention, to make the being of a gigantic stature, that is to say, about eight feet in height, and proportionably large. After having formed this determination and having spent some months in successfully collecting and arranging my materials, I began.",
            "Mary Shelley", "Frankenstein", 84,
            .init(warmth: 0.08, energy: 1.00, humor: 0.00, curiosity: 0.96, talkativeness: 0.60), 1.00
        ),

        quote(
            "comic.no-fire", .comicLens,
            "A poor, bare, miserable room it was, with broken windows, no fire, ragged bedclothes, a sick mother, wailing baby, and a group of pale, hungry children cuddled under one old quilt, trying to keep warm.",
            "Louisa May Alcott", "Little Women", 514,
            .init(warmth: 0.88, energy: 0.34, humor: 0.00, curiosity: 0.38, talkativeness: 0.50), 0.00
        ),
        quote(
            "comic.liniment-cake", .comicLens,
            "Mercy on us, Anne, you’ve flavored that cake with Anodyne Liniment. I broke the liniment bottle last week and poured what was left into an old empty vanilla bottle.",
            "L. M. Montgomery", "Anne of Green Gables", 45,
            .init(warmth: 0.58, energy: 0.62, humor: 0.25, curiosity: 0.46, talkativeness: 0.66), 0.25
        ),
        quote(
            "comic.croquet", .comicLens,
            "The balls were live hedgehogs, the mallets live flamingoes, and the soldiers had to double themselves up and to stand on their hands and feet, to make the arches.",
            "Lewis Carroll", "Alice’s Adventures in Wonderland", 11,
            .init(warmth: 0.48, energy: 0.72, humor: 0.50, curiosity: 0.82, talkativeness: 0.46), 0.50
        ),
        quote(
            "comic.fortuitous-crash", .comicLens,
            "It wavered an instant--then there was a heartrending crash--and the canary-coloured cart, their pride and their joy, lay on its side in the ditch, an irredeemable wreck. Toad sat straight down in the middle of the dusty road and stared fixedly in the direction of the disappearing motor-car. At intervals he faintly murmured ‘Poop-poop!’",
            "Kenneth Grahame", "The Wind in the Willows", 289,
            .init(warmth: 0.42, energy: 0.94, humor: 0.75, curiosity: 0.72, talkativeness: 0.64), 0.75
        ),
        quote(
            "comic.hedgehog-patient", .comicLens,
            "One day when an old lady with rheumatism came to see the Doctor, she sat on the hedgehog who was sleeping on the sofa and never came to see him any more, but drove every Saturday all the way to Oxenthorpe, another town ten miles off, to see a different doctor.",
            "Hugh Lofting", "The Story of Doctor Dolittle", 501,
            .init(warmth: 0.46, energy: 0.58, humor: 1.00, curiosity: 0.48, talkativeness: 0.72), 1.00
        ),

        quote(
            "dream.palaeontologist", .dream,
            "Ex-President Palaeontological Society. Publications: ‘Some Observations Upon a Series of Kalmuck Skulls’; ‘Outlines of Vertebrate Evolution’; and numerous papers, including ‘The underlying fallacy of Weissmannism,’ which caused heated discussion at the Zoological Congress of Vienna. Recreations: Walking, Alpine climbing.",
            "Arthur Conan Doyle", "The Lost World", 139,
            .init(warmth: 0.28, energy: 0.82, humor: 0.30, curiosity: 1.00, talkativeness: 0.66), 1.00
        ),
        quote(
            "dream.thousand-roses", .dream,
            "She did not want it to be a quite dead garden. If it were a quite alive garden, how wonderful it would be, and what thousands of roses would grow on every side!",
            "Frances Hodgson Burnett", "The Secret Garden", 17396,
            .init(warmth: 0.72, energy: 0.76, humor: 0.24, curiosity: 0.75, talkativeness: 0.64), 0.75
        ),
        quote(
            "dream.ballerina", .dream,
            "Up in the little garret there stands, half-dressed, a little Dancer. She stands now on one leg, now on both. The white dress is hanging on the hook; it was washed in the teapot, and dried on the roof. She puts it on, ties a saffron-colored kerchief round her neck, and then the gown looks whiter.",
            "Hans Christian Andersen", "The Snow Queen", 1597,
            .init(warmth: 0.62, energy: 0.58, humor: 0.36, curiosity: 0.00, talkativeness: 0.58), 0.00
        ),
        quote(
            "dream.puffed-sleeves", .dream,
            "It would give me such a thrill, Marilla, just to wear a dress with puffed sleeves.",
            "L. M. Montgomery", "Anne of Green Gables", 45,
            .init(warmth: 0.68, energy: 0.64, humor: 0.64, curiosity: 0.25, talkativeness: 0.62), 0.25
        ),
        quote(
            "dream.magic-inkstand", .dream,
            "I’d have a stable full of Arabian steeds, rooms piled high with books, and I’d write out of a magic inkstand, so that my works should be as famous as Laurie’s music.",
            "Louisa May Alcott", "Little Women", 514,
            .init(warmth: 0.54, energy: 0.84, humor: 0.28, curiosity: 0.50, talkativeness: 0.64), 0.50
        ),

        quote(
            "voice.seventeen-steps", .voice,
            "Now, I know that there are seventeen steps, because I have both seen and observed.",
            "Arthur Conan Doyle", "The Adventures of Sherlock Holmes", 1661,
            .init(warmth: 0.22, energy: 0.38, humor: 0.30, curiosity: 1.00, talkativeness: 0.00), 0.00
        ),
        quote(
            "voice.netherfield", .voice,
            "Why, my dear, you must know, Mrs. Long says that Netherfield is taken by a young man of large fortune from the north of England; that he came down on Monday in a chaise and four to see the place.",
            "Jane Austen", "Pride and Prejudice", 1342,
            .init(warmth: 0.46, energy: 0.56, humor: 0.48, curiosity: 0.58, talkativeness: 0.25), 0.25
        ),
        quote(
            "voice.animal-doors", .voice,
            "He wrote ‘HORSES’ over the front door, ‘COWS’ over the side door, and ‘SHEEP’ on the kitchen door. Each kind of animal had a separate door--even the mice had a tiny tunnel made for them into the cellar, where they waited patiently in rows.",
            "Hugh Lofting", "The Story of Doctor Dolittle", 501,
            .init(warmth: 0.68, energy: 0.48, humor: 0.48, curiosity: 0.68, talkativeness: 0.50), 0.50
        ),
        quote(
            "voice.motor-car-vow", .voice,
            "On the contrary, I faithfully promise that the very first motor-car I see, poop-poop! off I go in it!",
            "Kenneth Grahame", "The Wind in the Willows", 289,
            .init(warmth: 0.42, energy: 0.98, humor: 0.78, curiosity: 0.58, talkativeness: 0.75), 0.75
        ),
        quote(
            "voice.river", .voice,
            "By it and with it and on it and in it. It’s brother and sister to me, and aunts, and company, and food and drink, and washing. It’s my world, and I don’t want any other. When the floods are on in February, my cellars and basement are brimming with drink that’s no good to me.",
            "Kenneth Grahame", "The Wind in the Willows", 289,
            .init(warmth: 0.72, energy: 0.52, humor: 0.56, curiosity: 0.68, talkativeness: 1.00), 1.00
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
