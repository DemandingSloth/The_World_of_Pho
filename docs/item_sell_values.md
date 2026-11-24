# Item Marketplace Sell Values

Default (base) sell values for every sellable item, pulled from the definition
tables in `scripts/player_data.gd`. These are the **raw base values before any
multipliers**. See [How selling actually computes](#how-selling-actually-computes)
for the multiplier chains applied at sell time.

> Use the **Proposed** column to sketch new numbers. Nothing here changes the
> game until the matching constant in code is edited (pointers in each section).

---

## Gemstones — uncut
Source: `PROSPECTOR_GEM_ORDER` in `scripts/player_data.gd` (the `value` field).

| Item          | id             | Default | Proposed |
|---------------|----------------|--------:|---------:|
| Gold          | `gold`         |      50 |          |
| Blue Stone    | `blue_stone`   |      75 |          |
| Pink Stone    | `pink_stone`   |      75 |          |
| Violet Stone  | `violet_stone` |     100 |          |
| Black Pearl   | `black_pearl`  |     150 |          |
| Emerald       | `emerald`      |     200 |          |
| Ruby          | `ruby`         |     300 |          |
| Diamond       | `diamond`      |     500 |          |

---

## Gemstones — polished (Workshop saw output)
Polished value = uncut base × `POLISHED_VALUE_MULTIPLIER` (currently **10×**).
Gold is **not** polishable. Change the base (above) or the 10× constant to retune
all polished gems at once.

| Item                  | id             | Default | Proposed |
|-----------------------|----------------|--------:|---------:|
| Polished Blue Stone   | `blue_stone`   |     750 |          |
| Polished Pink Stone   | `pink_stone`   |     750 |          |
| Polished Violet Stone | `violet_stone` |   1,000 |          |
| Polished Black Pearl  | `black_pearl`  |   1,500 |          |
| Polished Emerald      | `emerald`      |   2,000 |          |
| Polished Ruby         | `ruby`         |   3,000 |          |
| Polished Diamond      | `diamond`      |   5,000 |          |

---

## Garden Crops
Source: `CROP_DEFS` in `scripts/player_data.gd` (the `base_price` field).

| Item         | id            | Default | Proposed |
|--------------|---------------|--------:|---------:|
| Beans        | `beans`       |      15 |          |
| Cucumbers    | `cucumbers`   |      36 |          |
| Peppers      | `peppers`     |      60 |          |
| Squash       | `squash`      |     105 |          |
| Grapes       | `grapes`      |     150 |          |
| Sunflower    | `sunflower`   |     195 |          |
| Cauliflower  | `cauliflower` |     225 |          |
| Pineapple    | `pineapple`   |     264 |          |
| Watermelon   | `watermelon`  |     300 |          |

---

## Orchard Fruit
Source: `ITEM_DEFS` in `scripts/player_data.gd` (the `sell_price` field).

| Item     | id        | Default | Proposed |
|----------|-----------|--------:|---------:|
| Plum     | `plum`    |     500 |          |
| Lemon    | `lemon`   |   1,000 |          |
| Apple    | `apple`   |   1,500 |          |
| Banana   | `banana`  |   2,000 |          |
| Coconut  | `coconut` |   2,500 |          |

---

## Resources — ores, bars & misc
Source: `RESOURCE_DEFS` in `scripts/player_data.gd` (the `sell_price` field).
`value_group` decides which prestige line scales it (see below).

| Item          | id             | Default | Group | Proposed |
|---------------|----------------|--------:|-------|---------:|
| Wood          | `wood`         |     500 | misc  |          |
| Stick         | `stick`        |     250 | misc  |          |
| Iron Ore      | `iron_ore`     |     750 | gem   |          |
| Iron Bar      | `iron_bar`     |   7,500 | gem   |          |
| Copper Ore    | `copper_ore`   |   1,000 | gem   |          |
| Copper Ingot  | `copper_ingot` |  10,000 | gem   |          |
| Gold Ingot    | `gold_ingot`   |  25,000 | gem   |          |

---

## Other sellable items

| Item          | id               | Default   | Notes                                   | Proposed |
|---------------|------------------|----------:|-----------------------------------------|---------:|
| Diamond Ring  | `diamond_ring`   |   500,000 | `DIAMOND_RING_SELL_PRICE` / `ITEM_DEFS` |          |
| Present (0–7) | `present_0..7`   |   500,000 | `PRESENT_SELL_VALUE` — flat, never scaled |        |

---

## Not sold on the marketplace (for reference)
- **Pho tiles** — sold back to the tile shop at **half their buy price**, not the
  marketplace. Buy prices come from `get_piece_price`. (Ask if you want these listed.)
- **Tools** — cannot be sold.

---

## How selling actually computes
Final per-unit payout = base value × the multipliers for that item's category.
All multipliers combine **multiplicatively**.

| Category | Base source | Prestige | Business District | Guild perk | Flat? |
|----------|-------------|----------|-------------------|------------|-------|
| Uncut gems          | `PROSPECTOR_GEM_ORDER.value` | `gem_profit` | — | `gem_sell_value` (+5%/lvl) | no |
| Polished gems       | base × 10 | `gem_profit` | — | `gem_sell_value` (+5%/lvl) | no |
| Ores/bars (gem grp) | `RESOURCE_DEFS.sell_price` | `gem_profit` | — | `gem_sell_value` (+5%/lvl) | no |
| Misc (wood/stick)   | `RESOURCE_DEFS.sell_price` | `misc_value` | — | — | no |
| Garden crops        | `CROP_DEFS.base_price` | `garden_profit` | crop-sell shops | `crop_sell_value` (+5%/lvl) | no |
| Orchard fruit       | `ITEM_DEFS.sell_price` | `fruit_profit` | fruit-sell shops | — | no |
| Diamond Ring        | `DIAMOND_RING_SELL_PRICE` | — | — | — | **yes** |
| Presents            | `PRESENT_SELL_VALUE` | — | — | — | **yes** |

Prestige sell-ramp (`gem_profit` / `garden_profit` / `fruit_profit` / `misc_value` /
`xp_boost`), per level 1→10: **+25, +75, +150, +250, +375, +525, +700, +850, +950,
+1000 %** (`SELL_PRICE_PRESTIGE_BONUS_PCT`). So a level-10 line is ×11.0.

Guild sell perks add **+5% per level** (max level 10 = +50%), and a linked guild's
perk adds on top, scaled by the `link_discount` upgrade.

### Where to edit in code
- Gems (uncut): `PROSPECTOR_GEM_ORDER` — `scripts/player_data.gd`
- Polished multiplier: `POLISHED_VALUE_MULTIPLIER` — `scripts/player_data.gd`
- Crops: `CROP_DEFS` (`base_price`) — `scripts/player_data.gd`
- Fruit: `ITEM_DEFS` (`sell_price`) — `scripts/player_data.gd`
- Resources: `RESOURCE_DEFS` (`sell_price`) — `scripts/player_data.gd`
- Diamond Ring: `DIAMOND_RING_SELL_PRICE` — `scripts/player_data.gd`
- Presents: `PRESENT_SELL_VALUE` — `scripts/player_data.gd`
- Prestige ramp: `SELL_PRICE_PRESTIGE_BONUS_PCT` — `scripts/player_data.gd`

---

_Snapshot of base values as of this doc's creation. If you change a constant in
code, update the matching Default here (or regenerate)._
