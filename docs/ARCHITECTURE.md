# The World of Pho — Architectural Overview & Contributor Guide

Welcome to **The World of Pho** codebase! This guide serves as a comprehensive reference to help you understand how the game is organized, where specific code resides, what each system does, and how components interact.

---

## 1. High-Level Overview & Tech Stack

- **Game Engine**: Godot Engine 4.x (Forward Plus / Mobile render pipelines).
- **Target Platforms**: Mobile (Android portrait orientation: 420x900 viewport base), Desktop / Web (HTML5/WASM).
- **Core Loop**:
  - Strategic tile/piece placement and movement battle system (board game mechanics against AI or multiplayer opponents).
  - Idle/incremental town economy: Garden, Orchard, Mining, Deep Mine, Gold Panning, Workshop, Business District, Horse Racing, and Guilds.
  - Character progression, prestige, jewelry bonuses, equipment, and achievements.
  - Multiplayer battles and online market trading powered by WebSockets and Supabase backend.
- **Architectural Pattern**: **Autoload State + Screen-per-Scene Navigation**.

---

## 2. Directory Layout

```text
WorldOfPho/
├── project.godot                # Godot project configuration and Autoload definitions
├── scenes/
│   ├── Main.tscn                # Shell scene hosting Persistent UI, Background, ScreenContainer, Navigator
│   ├── screens/                 # All individual modular screen UI scenes (*_screen.tscn)
│   ├── multiplayer/             # Multiplayer-specific scenes (lobby, match_result, piece_selection, etc.)
│   └── tutorial/                # Interactive tutorial overlay scenes
├── scripts/
│   ├── main.gd                  # Root script attached to Main.tscn (handles gestures, top bar updates)
│   ├── player_data.gd           # Core player profile, save/load persistence, wallet & inventory
│   ├── game_manager.gd          # Single-player battle loop state machine (phases, hand, placement, scoring)
│   ├── board_state.gd           # 2D Grid representation, cell occupants, obstacle/terrain handling
│   ├── piece.gd / piece_*.gd    # Pieces logic, definitions, catalog, and sprites
│   ├── terrain.gd               # Terrain mechanics (indoors, outdoors, ice, wind, etc.)
│   ├── movement.gd / scoring.gd # Battle movement rules and win/score calculation
│   ├── screens/                 # BaseScreen and screen controller scripts
│   ├── ai/                      # AI opponents (Wolf, Bear, NPC, Random) and enemy configs
│   ├── multiplayer/             # Multiplayer matchmaking, network synchronization, and lobby
│   ├── garden/                  # Garden crops and Hare Chase minigame
│   ├── orchard/                 # Fruit tree growth and harvest system
│   ├── mining/ & deep_mine/     # Standard mining & multi-layer Deep Mine incremental progression
│   ├── gold_panning/            # Shake/sift gold & gemstone panning minigame
│   ├── workshop/                # Gem crafting, cutting, jewelry forging
│   ├── business/                # Business District idle businesses, upgrades, and revenue
│   ├── horse_racing/            # Stable, horse breeding/training, sprint/hurdle minigames, racetrack
│   ├── guilds/                  # Cooperative guild progression, stockpiles, gardens, mines, store
│   ├── marketplace/             # Supabase cloud marketplace integration, account auth & charts
│   ├── mobile/                  # Android lifecycle, back button, touches, layout adjustments
│   ├── tutorial/                # Step-by-step guided tutorial controller & spotlights
│   └── ui/                      # Global UI components (TopBar, notifications, emoji fallbacks)
├── data/                        # Static JSON/Resource data definitions (pieces, recipes, etc.)
├── theme/                       # UI Themes and custom skin styling
├── tests/                       # Automated test suites for systems and UI scenes
└── supabase/                    # Backend database migrations and schemas for multiplayer/market
```

---

## 3. Core Architecture & Navigation System

### 3.1 The Shell: `scenes/Main.tscn` & `scripts/main.gd`

Rather than switching scenes using Godot's `get_tree().change_scene_to_file()`, the game runs inside a persistent master shell:

1. **`Background`**: Global background texture that individual screens can override or leave default.
2. **`ScreenContainer`**: An empty `Control` container where individual screen scenes are instantiated.
3. **`TopBar` (`scenes/screens/top_bar.tscn`)**: Persistent header showing player coins, level, gems, back button, and notifications.
4. **`ScreenNavigator` (`scripts/screens/screen_navigator.gd`)**: Node managing the active screen, navigation stack, and lifecycle.

### 3.2 The Screen System (`scripts/screens/base_screen.gd`)

Every screen scene (e.g. `town_screen.gd`, `battle_screen.gd`, `garden_screen.gd`) inherits from `BaseScreen`:

```gdscript
class_name BaseScreen
extends Control

func enter(params: Dictionary = {}) -> void: pass  # Setup UI & register signals
func exit() -> void: pass                         # Teardown & unregister signals
func get_screen_name() -> String: return ""       # Unique ID matching SCREEN_PATHS
func show_top_bar() -> bool: return true          # Hide top bar for full-screen games (e.g. battle)
func get_background_override() -> String: return "" # Optional custom backdrop
func allows_edge_swipe_back() -> bool: return true # False if screen uses horizontal touch gestures
```

### 3.3 Screen Navigator & Navigation Hierarchy

`ScreenNavigator` maintains `SCREEN_PATHS` (name-to-path mapping) and `SCREEN_PARENTS` for breadcrumb-like hierarchical navigation:

- `home` is the root screen.
- From `home`, you access `town`, `inventory`, `marketplace`, `workshop`, `guilds`, `achievements`.
- From `town`, you access `games`, `garden`, `mining`, `school`, `business_district`, `equestrian`, `prestige`.
- From `games`, you launch `setup` -> `prep` -> `battle` -> `result`.
- Back navigation uses `AndroidLifecycleManager` navigation stack or `SCREEN_PARENTS` fallbacks.

---

## 4. State Management & Autoload Singletons

The game uses Godot autoload singletons (`project.godot`) to persist state across screen swaps.

| Autoload | Script Path | Purpose |
| :--- | :--- | :--- |
| **`PlayerData`** | `scripts/player_data.gd` | Core state: player name, level, coins, tile inventory, active bonuses, save/load to `user://player_save.cfg`, backup files, and offline progress calculations. |
| **`TrustedClock`** | `scripts/trusted_clock.gd` | Anti-tampering network/server clock for crop growth, offline yields, and timers. |
| **`PieceRegistry`** | `scripts/piece_registry.gd` | Master database of pieces, tiers, stats, and unlock criteria. |
| **`PieceSprites`** | `scripts/piece_sprites.gd` | Texture manager for piece visuals. |
| **`TerrainSprites`** | `scripts/terrain_sprites.gd` | Textures for different environmental tiles. |
| **`Achievements`** | `scripts/achievement_manager.gd` | Tracks milestones, unlocks, and rewards. |
| **`Garden`** | `scripts/garden/garden_data.gd` | Garden plots, planted seeds, watering, timers, harvests. |
| **`Orchard`** | `scripts/orchard/orchard_data.gd` | Orchard tree stages, fruit collection, tree levels. |
| **`DeepMine`** | `scripts/deep_mine/deep_mine_data.gd` | Deep Mine depths, excavator upgrades, ore drops. |
| **`Workshop`** | `scripts/workshop/workshop_data.gd` | Gem cutting, jewelry crafting recipes, and workbench levels. |
| **`BusinessDistrict`** | `scripts/business/business_district_data.gd` | Idle shops, upgrades, offline business earnings. |
| **`HorseRacing`** | `scripts/horse_racing/horse_racing_data.gd` | Horses, stats (speed, stamina), breeding, race entries, bets. |
| **`GuildManager`** | `scripts/guilds/guild_manager.gd` | Guild memberships, role management, communication. |
| **`MoneyGun`** | `scripts/money_gun_data.gd` | Clicker/tapper mini-mechanic for bonus coin prestige. |
| **`JewelryBonus`** | `scripts/jewelry_bonus.gd` | Stat multipliers granted by equipped rings, necklaces, and charms. |
| **`AndroidLifecycleManager`** | `scripts/mobile/android_lifecycle_manager.gd` | Android lifecycle, back button handling, suspend/resume, idle recovery. |
| **`SupabaseClient`** | `scripts/marketplace/supabase_client.gd` | REST & WebSocket connector for Supabase backend. |

---

## 5. Major Subsystems & Flow

### 5.1 Battle Engine (Turn-based Board Game)

- **Files**: `scripts/game_manager.gd`, `scripts/board_state.gd`, `scripts/piece.gd`, `scripts/movement.gd`, `scripts/scoring.gd`
- **Flow**:
  1. `setup_screen.gd`: Player chooses enemy and terrain conditions (e.g. wind, mud, ice).
  2. `prep_screen.gd`: Player selects pieces from inventory to bring into the match.
  3. `battle_screen.gd` + `GameManager`:
     - **Placement Phase**: Alternating turns placing pieces on the `BoardState` grid.
     - **Movement Phase**: Pieces move according to their movement rules (`movement.gd`), interacting with terrain mechanics (e.g., wind pushing tiles, ice sliding).
     - **Scoring Phase**: `scoring.gd` calculates area influence, captured points, and bonuses.
     - **Result Phase**: Rewards player with coins and progression rewards.

### 5.2 Artificial Intelligence (`scripts/ai/`)

- Base class: `AIBase` (`scripts/ai/ai_base.gd`).
- Implementations:
  - `ai_random.gd`: Random moves (Easy).
  - `ai_npc.gd`: Heuristic evaluation of board territory (Medium).
  - `ai_wolf.gd`: Aggressive flanker strategy (Hard).
  - `ai_bear.gd`: Defensive territorial anchor strategy (Brutal).

### 5.3 Town & Idle Economies

Each feature in town is built with decoupled logic:

1. **Data Singleton (`*_data.gd`)**: Pure game logic, timers, leveling calculations, save data serialization.
2. **Screen Controller (`*_screen.gd`)**: Handles buttons, animations, displays, and reads from the Data Singleton.

Example: **Garden System**:

- `scripts/garden/garden_data.gd`: Handles plot states, seed types, timers.
- `scripts/garden/garden_ui.gd` & `scripts/screens/garden_screen.gd`: Render the visual plots.
- `scripts/screens/hare_chase_screen.gd`: Minigame triggered when pests attack the garden.

### 5.4 Multiplayer & Online Marketplace

- **Multiplayer**: `scripts/multiplayer/` handles peer discovery, lobby matching, and `board_sync.gd` for state synchronization over WebSockets.
- **Marketplace**: `scripts/marketplace/` interacts with Supabase for player-to-player item trading, price histories (`price_chart.gd`), and secure authentication.

### 5.5 Mobile Adaptations (`scripts/mobile/`)

- `touch_input_manager.gd` & `grid_pan_controller.gd`: Touch gestures, pinching, and drag navigation on small screens.
- `responsive_layout_manager.gd`: Dynamic responsive anchor repositioning for notched devices.
- `android_lifecycle_manager.gd`: Handles app pausing, backgrounding, battery saving, and offline calculation on resume.

---

## 6. How to Contribute: Common Recipes

### Adding a New Screen

1. Create your UI scene under `res://scenes/screens/my_new_screen.tscn`.
2. Attach a script inheriting `BaseScreen`:

   ```gdscript
   class_name MyNewScreen
   extends BaseScreen

   func get_screen_name() -> String:
       return "my_new_feature"

   func enter(params: Dictionary = {}) -> void:
       # Initialize view
       pass
   ```

3. Register the new screen in `scripts/screens/screen_navigator.gd`:
   - Add entry to `SCREEN_PATHS`: `"my_new_feature": "res://scenes/screens/my_new_screen.tscn"`
   - Add parent relationship in `SCREEN_PARENTS`: `"my_new_feature": "town"` (or appropriate parent).
4. Navigate to it from anywhere via:

   ```gdscript
   _get_navigator().navigate_to("my_new_feature", { "custom_param": 123 })
   ```

### Adding New Inventory Items / Pieces

1. **Piece**: Register definition in `scripts/piece_definition.gd` and add entries to `scripts/piece_registry.gd`. Add sprites to `scripts/piece_sprites.gd`.
2. **Save Data**: Update `PlayerData` (`scripts/player_data.gd`) if new item types need custom persistence or default counts.

### Writing Tests

- All tests are located in `tests/`.
- Run or add test files using Godot's test framework or custom test runner scripts (e.g. `tests/test_*.gd`).

---

## 7. Key Conventions & Best Practices

- **Never directly change scenes**: Always use `ScreenNavigator.navigate_to()` or `ScreenNavigator.navigate_back()`.
- **Decouple Data from UI**: Screen classes (`*_screen.gd`) should not hold authoritative game data. Always query and mutate through the appropriate singleton (`PlayerData`, `Garden`, `Workshop`, etc.).
- **Signal Cleanup**: Always disconnect custom signals in `exit()` if connecting dynamically, preventing memory leaks when screens are unloaded.
- **Mobile-First UX**: Design UI for portrait orientation (420x900 base size), keeping clickable touch targets at least 48x48 px.
