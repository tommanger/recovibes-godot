# RecoVibes for Godot

Show recommendations from the RecoVibes network inside your game, and get your game recommended in others. The cards are drawn with Godot's own UI nodes, so they sit anywhere in your interface and follow your layout.

Godot 4.2 or newer.

## Install

- **Asset Library:** search for **RecoVibes** in the AssetLib tab and install.
- **Or by hand:** copy `addons/recovibes` into your project's `addons/` folder.

Then **Project → Project Settings → Plugins** and enable **RecoVibes** (optional - the node works without it).

## Use

1. Add a **RecoVibesWidget** node (it's a Control) where you want recommendations.
2. Paste your app's **Data Id** from the RecoVibes dashboard (your app → Install tab).
3. Size the node. The widget fills it with as many cards as fit, or set **Slots** for a fixed number.

From code:

```gdscript
var reco := RecoVibesWidget.new()
reco.data_id = "rv_xxxxxxxx"
reco.layout = RecoVibesWidget.Layout.HORIZONTAL
$Panel.add_child(reco)
reco.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
```

## How it counts

- A card counts as viewed once half of it has been on screen for a second while your game has focus. Hidden, transparent, clipped and off-screen cards don't count.
- Each time the node enters the tree counts as a new screen view.
- A tap reports the click, then opens the app's store page (App Store on iPhone, Google Play on Android, Steam / itch.io on computers). To route links yourself, set `open_url` to a Callable.
- Views from the Godot editor never earn points. Your app earns points once its store listing is verified in the dashboard.

## Options

| Property | What it does |
| --- | --- |
| slots | 0 = as many as fit; otherwise a fixed number (up to 12) |
| layout | VERTICAL list or HORIZONTAL row |
| theme_mode | From your dashboard design, or LIGHT / DARK |
| font | Your game's font (default: Godot's) |
| card_height / min_card_width / spacing | Card sizing |

## Tests

```sh
godot --headless --path . --import
godot --headless --path . --script res://tests/run_tests.gd
```
