import Foundation

struct FoodIconMatcher {
    static let iconFiles: [String] = [
        "Apple.svg","Asparagus.svg","Avocado.svg","Baby Bottle.svg","Bacon.svg",
        "Banana.svg","Banana Split.svg","Bar.svg","Bavarian Beer Mug.svg","Bavarian Pretzel.svg",
        "Bavarian Wheat Beer.svg","Beer Bottle.svg","Beer Can.svg","Beer.svg","Beet.svg",
        "Birthday Cake.svg","Bottle of Water.svg","Bread.svg","Broccoli.svg","Cabbage.svg",
        "Cafe.svg","Carrot.svg","Celery.svg","Cheese.svg","Cherry.svg","Chili Pepper.svg",
        "Cinnamon Roll.svg","Citrus.svg","Cocktail.svg","Coconut Cocktail.svg","Coffee Pot.svg",
        "Coffee to Go.svg","Cookies.svg","Corn.svg","Cotton Candy.svg","Crab.svg","Cucumber.svg",
        "Cup.svg","Cupcake.svg","Dim Sum.svg","Dolmades.svg","Doughnut.svg","Dragon Fruit.svg",
        "Durian.svg","Eggplant.svg","Eggs.svg","Espresso Cup.svg","Fish Food.svg","Food And Wine.svg",
        "French Fries.svg","French Press.svg","Garlic.svg","Grapes.svg","Hamburger.svg","Hazelnut.svg",
        "Honey.svg","Hops.svg","Hot Chocolate.svg","Hot Dog.svg","Ice Cream Cone.svg","Ingredients.svg",
        "Kebab.svg","Kiwi.svg","Kohlrabi.svg","Leek.svg","Lettuce.svg","Macaron.svg","Melon.svg",
        "Milk.svg","Nachos.svg","Natural Food.svg","Noodles.svg","Nut.svg","Octopus.svg","Olive Oil.svg",
        "Olive.svg","Onion.svg","Organic Food.svg","Pancake.svg","Paprika.svg","Pastry Bag.svg",
        "Peach.svg","Peanuts.svg","Pear.svg","Peas.svg","Pepper Shaker.svg","Pie.svg","Pineapple.svg",
        "Pizza.svg","Plum.svg","Pomegranate.svg","Porridge.svg","Potato.svg","Prawn.svg","Pretzel.svg",
        "Quesadilla.svg","Rack of Lamb.svg","Radish.svg","Raspberry.svg","Rice Bowl.svg","Sack of Flour.svg",
        "Salt Shaker.svg","Sauce.svg","Sesame.svg","Spaghetti.svg","Spoon of Sugar.svg","Steak.svg",
        "Strawberry.svg","Sugar Cube.svg","Sugar.svg","Sushi.svg","Sweet Potato.svg","Taco.svg","Tapas.svg",
        "Tea Cup.svg","Tea.svg","Teapot.svg","Thanksgiving.svg","Tin Can.svg","Tomato.svg","Vegan Food.svg",
        "Vegan Symbol.svg","Watermelon.svg","Wine Bottle.svg","Wine Glass.svg","Wrap.svg","Whey.svg","Peanut Butter.svg",
        "Sweetener.svg","Quinoa.svg","Cheesecake.svg","Bagel.svg","Miso Soup.svg","Cola.svg","Lemonade.svg",
        "Bao.svg","Matcha.svg","Soy Sauce.svg","Cashew.svg","Samosa.svg","Spinach.svg","Waffle.svg",
        "Tofu.svg","Soup.svg","Salami.svg","Macaroni.svg","Gum.svg","Croissant.svg","Sausage.svg",
        "Maple.svg","Butter.svg","Cloves.svg","Cinnamon.svg","Raisin.svg","Chips.svg","Cereal.svg",
        "Green Tea.svg","Kimchi.svg","Bento.svg","Caviar.svg","Falafel.svg","Salad.svg",
        "Yogurt.svg","Gyoza.svg","Spread.svg","Jelly.svg","Boba.svg","Naan.svg","Spam.svg","Date.svg",
        "Salmon.svg","Rice Cake.svg","Sashimi.svg"
    ]

    private static let pngIconFiles: [String] = [
        "Bagel.png","Bao.png","Bento.png","Boba.png","Butter.png","Cashew.png","Caviar.png",
        "Cereal.png","Cheesecake.png","Chips.png","Cinnamon.png","Cloves.png","Cola.png",
        "Croissant.png","Curry.png","Date.png","DefaultFood.png","Dim Sum.png","Falafel.png",
        "Green Tea.png","Gum.png","Gyoza.png","Jelly.png","Kimchi.png","Lemonade.png",
        "Macaroni.png","Maple.png","Matcha.png","Miso Soup.png","Naan.png","Peanut Butter.png",
        "Quinoa.png","Raisin.png","Rice Cake.png","Salad.png","Salami.png","Salmon.png",
        "Samosa.png","Sashimi.png","Sausage.png","Soup.png","Soy Sauce.png","Spam.png",
        "Spinach.png","Spread.png","Sweetener.png","Tiramisu.png","Tofu.png","Waffle.png",
        "Whey.png","Yogurt.png"
    ]

    private static let pngIconBases = Set(pngIconFiles.map(iconBase))
    private static let availableIconFiles: Set<String> = {
        let generatedPngs = iconFiles.map { "\(iconBase($0)).png" }
        return Set(iconFiles.filter { !pngIconBases.contains(iconBase($0)) } + pngIconFiles + generatedPngs)
    }()

    // 2) Common-name aliases → canonical icon filename
    //    Keys are normalized (singular forms only - plurals handled automatically); values must match an entry in iconFiles
    static var aliases: [String:String] = [
        // Produce & staples
        "apple": "Apple.svg",
        "greenapple": "Apple.svg",
        "cashew": "Cashew.svg",
        "banana": "Banana.svg",
        "bananasplit": "Banana Split.svg",
        "plantain": "Banana.svg",
        "avocado": "Avocado.svg",
        "asparagus": "Asparagus.svg",
        "aubergine": "Eggplant.svg",
        "eggplant": "Eggplant.svg",
        "brinjal": "Eggplant.svg",
        "chili": "Chili Pepper.svg",
        "chilli": "Chili Pepper.svg",
        "chilipepper": "Chili Pepper.svg",
        "bellpepper": "Chili Pepper.svg",
        "capsicum": "Chili Pepper.svg",
        "paprika": "Paprika.svg",
        "carrot": "Carrot.svg",
        "celery": "Celery.svg",
        "broccoli": "Broccoli.svg",
        "cabbage": "Cabbage.svg",
        "lettuce": "Lettuce.svg",
        "beet": "Beet.svg",
        "beetroot": "Beet.svg",
        "radish": "Radish.svg",
        "onion": "Onion.svg",
        "garlic": "Garlic.svg",
        "leek": "Leek.svg",
        "kohlrabi": "Kohlrabi.svg",
        "potato": "Potato.svg",
        "sweetpotato": "Sweet Potato.svg",
        "yam": "Sweet Potato.svg",
        "tomato": "Tomato.svg",
        "cucumber": "Cucumber.svg",
        "corn": "Corn.svg",
        "maize": "Corn.svg",
        "peas": "Peas.svg",
        "greenpeas": "Peas.svg",
        "grape": "Grapes.svg",
        "cherry": "Cherry.svg",
        "berries": "Raspberry.svg",
        "raspberry": "Raspberry.svg",
        "strawberry": "Strawberry.svg",
        "citrus": "Citrus.svg",
        "orange": "Citrus.svg",
        "lemon": "Citrus.svg",
        "lime": "Citrus.svg",
        "grapefruit": "Citrus.svg",
        "mandarin": "Citrus.svg",
        "tangerine": "Citrus.svg",
        "kiwi": "Kiwi.svg",
        "pineapple": "Pineapple.svg",
        "pear": "Pear.svg",
        "peach": "Peach.svg",
        "plum": "Plum.svg",
        "pomegranate": "Pomegranate.svg",
        "melon": "Melon.svg",
        "watermelon": "Watermelon.svg",
        "olive": "Olive.svg",
        "oliveoil": "Olive Oil.svg",
        "durian": "Durian.svg",
        "dragonfruit": "Dragon Fruit.svg",
        "hazelnut": "Hazelnut.svg",
        "peanut": "Peanuts.svg",
        "sesame": "Sesame.svg",
        "nut": "Nut.svg",

        // Bakery & sweets
        "bread": "Bread.svg",
        "toast": "Bread.svg",
        "cake": "Birthday Cake.svg",
        "birthdaycake": "Birthday Cake.svg",
        "cupcake": "Cupcake.svg",
        "doughnut": "Doughnut.svg",
        "donut": "Doughnut.svg",
        "cinnamonroll": "Cinnamon Roll.svg",
        "pie": "Pie.svg",
        "cookie": "Cookies.svg",
        "icecream": "Ice Cream Cone.svg",
        "icecreamcone": "Ice Cream Cone.svg",
        "macaron": "Macaron.svg",
        "macaroon": "Macaron.svg",
        "pastry": "Pastry Bag.svg",
        "pancake": "Pancake.svg",
        "cottoncandy": "Cotton Candy.svg",
        "sugar": "Sugar.svg",
        "sugarcube": "Sugar Cube.svg",
        "spoonofsugar": "Spoon of Sugar.svg",
        "flour": "Sack of Flour.svg",
        "baguette": "Bread.svg",
        "sourdough": "Bread.svg",
        "bun": "Bread.svg",
        "roll": "Bread.svg",
        "tortilla": "Wrap.svg",

        // Meals & fast food
        "hamburger": "Hamburger.svg",
        "burger": "Hamburger.svg",
        "cheeseburger": "Hamburger.svg",
        "hotdog": "Hot Dog.svg",
        "pizza": "Pizza.svg",
        "frenchfries": "French Fries.svg",
        "fries": "French Fries.svg",
        "chips": "Chips.png",
        "crisps": "Chips.png",
        "taco": "Taco.svg",
        "burrito": "Wrap.svg",
        "wrap": "Wrap.svg",
        "quesadilla": "Quesadilla.svg",
        "nachos": "Nachos.svg",
        "kebab": "Kebab.svg",
        "doner": "Kebab.svg",
        "sushi": "Sushi.svg",
        "nigiri": "Sushi.svg",
        "maki": "Sushi.svg",
        "dimsum": "Dim Sum.svg",
        "dumpling": "Dim Sum.svg",
        "shumai": "Dim Sum.svg",
        "dolma": "Dolmades.svg",
        "spaghetti": "Spaghetti.svg",
        "pasta": "Spaghetti.svg",
        "lasagna": "Spaghetti.svg",
        "ravioli": "Spaghetti.svg",
        "noodles": "Noodles.svg",
        "ramen": "Noodles.svg",
        "pho": "Noodles.svg",
        "udon": "Noodles.svg",
        "soba": "Noodles.svg",
        "rice": "Rice Bowl.svg",
        "friedrice": "Rice Bowl.svg",
        "porridge": "Porridge.svg",
        "oatmeal": "Porridge.svg",
        "oats": "Porridge.svg",
        "granola": "Cereal.svg",
        "cereal": "Cereal.svg",
        "bowl": "Rice Bowl.svg",
        "ricebowl": "Rice Bowl.svg",
        "biryani": "Rice Bowl.svg",
        "pilaf": "Rice Bowl.svg",
        "risotto": "Rice Bowl.svg",
        "macandcheese": "Macaroni.svg",
        "macaroni": "Macaroni.svg",
        "mac": "Macaroni.svg",
        "salad": "Salad.svg",
        "caesarsalad": "Salad.svg",
        "greensalad": "Salad.svg",
        "curry": "Curry.png",
        "stew": "Soup.svg",
        "broth": "Soup.svg",

        // Protein & seafood
        "steak": "Steak.svg",
        "beef": "Steak.svg",
        "sirloin": "Steak.svg",
        "ribeye": "Steak.svg",
        "pork": "Bacon.svg",
        "bacon": "Bacon.svg",
        "lamb": "Rack of Lamb.svg",
        "rackoflamb": "Rack of Lamb.svg",
        "egg": "Eggs.svg",
        "eggs": "Eggs.svg",
        "scrambledeggs": "Eggs.svg",
        "scrambledegg": "Eggs.svg",
        "boiledegg": "Eggs.svg",
        "hardboiledegg": "Eggs.svg",
        "softboiledegg": "Eggs.svg",
        "friedegg": "Eggs.svg",
        "eggwhite": "Eggs.svg",
        "eggwhites": "Eggs.svg",
        "omelette": "Eggs.svg",
        "omelet": "Eggs.svg",
        "cheese": "Cheese.svg",
        "milk": "Milk.svg",
        "babybottle": "Baby Bottle.svg",
        "formula": "Baby Bottle.svg",
        "prawn": "Prawn.svg",
        "shrimp": "Prawn.svg",
        "crab": "Crab.svg",
        "octopus": "Octopus.svg",
        "fish": "Fish Food.svg",
        "seafood": "Fish Food.svg",
        "salmon": "Salmon.svg",
        "sashimi": "Sashimi.svg",
        "tuna": "Fish Food.svg",
        "cod": "Fish Food.svg",
        "tilapia": "Fish Food.svg",
        "chicken": "Thanksgiving.svg",
        "chickenbreast": "Thanksgiving.svg",
        "chickenthigh": "Thanksgiving.svg",
        "turkey": "Thanksgiving.svg",
        "tofu": "Tofu.svg",
        "tempeh": "Tofu.svg",
        "sausage": "Sausage.svg",
        "salami": "Salami.svg",

        // Drinks & cafe
        "coffee": "Coffee to Go.svg",
        "latte": "Coffee to Go.svg",
        "mocha": "Coffee to Go.svg",
        "americano": "Espresso Cup.svg",
        "espresso": "Espresso Cup.svg",
        "cappuccino": "Espresso Cup.svg",
        "frenchpress": "French Press.svg",
        "coffeepot": "Coffee Pot.svg",
        "cafe": "Cafe.svg",
        "tea": "Tea Cup.svg",
        "chai": "Tea Cup.svg",
        "teacup": "Tea Cup.svg",
        "teapot": "Teapot.svg",
        "hotchocolate": "Hot Chocolate.svg",
        "cocoa": "Hot Chocolate.svg",
        "waterbottle": "Bottle of Water.svg",
        "bottleofwater": "Bottle of Water.svg",
        "water": "Bottle of Water.svg",
        "cup": "Cup.svg",
        "juice": "Cup.svg",
        "smoothie": "Cup.svg",
        "shake": "Cup.svg",
        "soda": "Cup.svg",
        "pop": "Cup.svg",
        "cola": "Cola.svg",
        "coke": "Cola.svg",
        "dietcoke": "Cola.svg",
        "cocktail": "Cocktail.svg",
        "mocktail": "Cocktail.svg",
        "beer": "Beer.svg",
        "lager": "Beer.svg",
        "ale": "Beer.svg",
        "beercan": "Beer Can.svg",
        "beermug": "Bavarian Beer Mug.svg",
        "draft": "Bavarian Beer Mug.svg",
        "wine": "Wine Glass.svg",
        "redwine": "Wine Glass.svg",
        "whitewine": "Wine Glass.svg",
        "winebottle": "Wine Bottle.svg",

        // Seasoning & misc.
        "salt": "Salt Shaker.svg",
        "pepper": "Pepper Shaker.svg",
        "sauce": "Sauce.svg",
        "ketchup": "Sauce.svg",
        "mustard": "Sauce.svg",
        "hot sauce": "Sauce.svg",
        "hotsauce": "Sauce.svg",
        "ingredients": "Ingredients.svg",
        "hops": "Hops.svg",

        // Diet / badges
        "vegan": "Vegan Symbol.svg",
        "vegansymbol": "Vegan Symbol.svg",
        "veganfood": "Vegan Food.svg",
        "organic": "Organic Food.svg",
        "natural": "Natural Food.svg",
        "thanksgiving": "Thanksgiving.svg",

        "shawarma": "Wrap.svg",
        "mayonnaise": "Sauce.svg",
        "mayo": "Sauce.svg",
        "mayonise": "Sauce.svg",

        "oatlight": "Milk.svg",
        "oatlightmilk": "Milk.svg",
        "silk": "Milk.svg",
        "silkmilk": "Milk.svg",
        "hashbrown": "Potato.svg",
        "hashbrowns": "Potato.svg",
        "cheddar": "Cheese.svg",
        "mozzarella": "Cheese.svg",
        "parmesan": "Cheese.svg",
        "provolone": "Cheese.svg",
        "romano": "Cheese.svg",
        "feta": "Cheese.svg",
        "fishfood": "Fish Food.svg",
        "almond": "Nut.svg",
        "protein": "Whey.svg",
        "proteinpowder": "Whey.svg",
        "proteinshake": "Whey.svg",
        "whey": "Whey.svg",
        "peanutbutter": "Peanut Butter.svg",
        "sweetener": "Sweetener.svg",
        "quinoa": "Quinoa.svg",
        "cheesecake": "Cheesecake.svg",
        "bagel": "Bagel.svg",
        "misosoup": "Miso Soup.svg",
        "miso": "Miso Soup.svg",
        "lemonade": "Lemonade.svg",
        "bao": "Bao.svg",
        "matcha": "Matcha.svg",
        "soysauce": "Soy Sauce.svg",
        "soy": "Soy Sauce.svg",
        "samosa": "Samosa.svg",
        "spinach": "Spinach.svg",
        "waffle": "Waffle.svg",
        "soup": "Soup.svg",
        "gum": "Gum.svg",
        "croissant": "Croissant.svg",
        "maple": "Maple.svg",
        "maplesyrup": "Maple.svg",
        "butter": "Butter.svg",
        "clove": "Cloves.svg",
        "cinnamon": "Cinnamon.svg",
        "raisin": "Raisin.svg",
        "chip": "Chips.svg",
        "potatochip": "Chips.svg",
        "greentea": "Green Tea.svg",
        "kimchi": "Kimchi.svg",
        "bento": "Bento.svg",
        "caviar": "Caviar.svg",
        "falafel": "Falafel.svg",
        "yogurt": "Yogurt.svg",
        "yoghurt": "Yogurt.svg",
        "greekyogurt": "Yogurt.svg",
        "skyr": "Yogurt.svg",
        "gyoza": "Gyoza.svg",
        "spread": "Spread.svg",
        "jelly": "Jelly.svg",
        "boba": "Boba.svg",
        "bubbletea": "Boba.svg",
        "naan": "Naan.svg",
        "spam": "Spam.svg",
        "date": "Date.svg",
        "ricecake": "Rice Cake.svg",
        "tiramisu": "Tiramisu.svg",
        "cauliflower": "Cauliflower.svg"
    ]

    // MARK: - Public API

    /// Find the best icon filename for a free-form food string.
    static func icon(for input: String) -> String? {
        let n = normalize(input)

        // 1) Alias hit by substring (pick longest alias hit)
        if let aliasHit = bestAliasMatch(in: n) {
            return resolveIconFile(aliasHit)
        }

        // 2) Partial match against actual filenames (prefer longest icon-name hit)
        if let fileHit = bestFilenameMatch(in: n) {
            return resolveIconFile(fileHit)
        }

        return nil
    }

    /// Allow apps to extend/override alias mapping at runtime
    static func registerAlias(_ alias: String, mapsTo iconFile: String) {
        let key = normalize(alias)
        guard let resolved = resolveIconFile(iconFile) else { return }
        aliases[key] = resolved
    }

    // MARK: - Internals

    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
    }

    private static func resolveIconFile(_ file: String) -> String? {
        if availableIconFiles.contains(file) {
            return file
        }

        let base = iconBase(file)

        if availableIconFiles.contains("\(base).png") {
            return "\(base).png"
        }
        if availableIconFiles.contains("\(base).svg") {
            return "\(base).svg"
        }
        return nil
    }

    private static func iconBase(_ file: String) -> String {
        file
            .replacingOccurrences(of: ".svg", with: "")
            .replacingOccurrences(of: ".png", with: "")
    }

    /// Convert plural to singular form (removes 's' or 'es' ending)
    private static func singularize(_ s: String) -> String {
        if s.hasSuffix("es") && s.count > 2 {
            return String(s.dropLast(2))
        } else if s.hasSuffix("s") && s.count > 1 {
            return String(s.dropLast())
        }
        return s
    }

    /// Get both original and singularized versions for matching
    private static func getMatchingVariants(_ normalizedInput: String) -> [String] {
        var variants = [normalizedInput]
        let singular = singularize(normalizedInput)
        if singular != normalizedInput {
            variants.append(singular)
        }
        return variants
    }

    private static func bestAliasMatch(in normalizedInput: String) -> String? {
        let variants = getMatchingVariants(normalizedInput)
        var exactMatch: (len: Int, file: String)? = nil
        var best: (len: Int, file: String)? = nil

        for variant in variants {
            for (alias, file) in aliases {
                // Prioritize exact matches
                if alias == variant {
                    if exactMatch == nil || alias.count > exactMatch!.len {
                        exactMatch = (alias.count, file)
                    }
                }
                // Then check substring matches
                else if alias.count >= 4 && variant.contains(alias) {
                    if best == nil || alias.count > best!.len {
                        best = (alias.count, file)
                    }
                }
            }
        }

        // Return exact match if found, otherwise best substring match
        return exactMatch?.file ?? best?.file
    }

    private static let normalizedIcons: [(key:String, file:String)] = {
        availableIconFiles
            .filter { $0 != "DefaultFood.png" }
            .map { file in
            let base = iconBase(file)
            return (normalize(base), file)
        }
        .sorted { $0.key.count > $1.key.count }
    }()

    private static func bestFilenameMatch(in normalizedInput: String) -> String? {
        let variants = getMatchingVariants(normalizedInput)
        var best: (len: Int, file: String)? = nil

        for variant in variants {
            for (key, file) in normalizedIcons {
                if variant == key || (key.count >= 4 && variant.contains(key)) {
                    if best == nil || key.count > best!.len {
                        best = (key.count, file)
                    }
                }
            }
        }
        return best?.file
    }
}
