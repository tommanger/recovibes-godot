@icon("res://addons/recovibes/icon.svg")
class_name RecoVibesWidget
extends Control
## Shows recommendations from the RecoVibes network inside this Control.
##
## Add a RecoVibesWidget node to any UI, set [member data_id] and size it: the
## widget fills the rectangle with as many cards as fit (or [member slots]).
## A card counts as viewed once half of it has been on screen for a second
## while the game has focus; a tap opens the app's store page. Each time the
## node enters the tree counts as a new screen view, like a page load.

const WIDGET_VERSION := "godot-1"
const PACKAGE_VERSION := "1.0.0"
const MAX_SLOTS := 12
const PADDING := 12.0
const HEADING_HEIGHT := 20.0
const ATTRIBUTION_URL := "https://recovibes.com/?utm_source=godot&utm_medium=attribution"
const DEFAULT_ACCENT := Color("#7e7eff")

enum Layout { VERTICAL, HORIZONTAL }
enum ThemeMode { FROM_DASHBOARD, LIGHT, DARK }

## Your app's ID from the RecoVibes dashboard (Install tab), e.g. rv_ab12cd34.
@export var data_id := ""
## How many recommendations to show. 0 = as many as fit.
@export_range(0, 12) var slots := 0
## A list of cards, or cards side by side.
@export var layout := Layout.VERTICAL
## FROM_DASHBOARD uses the theme from your RecoVibes design (dark when it's Auto).
@export var theme_mode := ThemeMode.FROM_DASHBOARD
## Optional: your game's font.
@export var font: Font
@export var card_height := 76.0
@export var min_card_width := 200.0
@export var spacing := 10.0
## Leave as is, unless you test against your own RecoVibes server.
@export var api_base := "https://api.recovibes.com"

## Emitted after each render with the number of cards shown (0 = nothing to show).
signal rendered(count: int)
## Emitted for every report sent (tests and debugging).
signal tracked(type: String, target: String)

## Opens a tapped card's link. Set it to route links yourself.
var open_url: Callable = func(url: String) -> void: OS.shell_open(url)

var _data: Dictionary = {}
var _receipt := ""
var _shown := 0
var _host_seen := false
var _seen := {}
var _cards: Array = []  # [{card: Dictionary, node: Control, visible_for: float}]
var _content: Control
var _rendered_size := Vector2.ZERO
var _tick := 0.0
var _last_click := -10.0
var _focused := true


static func auto_slots(lay: int, width: float, height: float, heading: bool, card_h: float, min_w: float, gap: float, heading_h: float) -> int:
	var n: int
	if lay == Layout.VERTICAL:
		var room := height - (heading_h + gap if heading else 0.0)
		n = floori((room + gap) / (card_h + gap))
	else:
		n = floori((width + gap) / (min_w + gap))
	return clampi(n, 1, MAX_SLOTS)


static func visible_fraction(item: Rect2, view: Rect2) -> float:
	var area := item.size.x * item.size.y
	if area <= 0.0:
		return 0.0
	var inter := item.intersection(view)
	return clampf(inter.size.x * inter.size.y / area, 0.0, 1.0)


static func new_click_id() -> String:
	var crypto := Crypto.new()
	return crypto.generate_random_bytes(16).hex_encode()


static func heading_for(lang: String) -> String:
	match lang:
		"he": return "אולי יעניין אותך"
		"es": return "También te puede gustar"
		"fr": return "Vous aimerez aussi"
		"de": return "Das könnte dir auch gefallen"
		"pt": return "Você também pode gostar"
		"it": return "Potrebbe piacerti anche"
		"ru": return "Вам также может понравиться"
	return "You might also like"


func _ready() -> void:
	resized.connect(_on_resized)


func _enter_tree() -> void:
	if Engine.is_editor_hint():
		return
	if data_id.strip_edges() == "":
		push_warning("[RecoVibes] Set data_id from your RecoVibes dashboard (Install tab).")
		return
	_load.call_deferred()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_focused = false
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_focused = true


func _load() -> void:
	await get_tree().process_frame  # let the layout settle so we know our size
	var http := HTTPRequest.new()
	http.timeout = 10.0
	add_child(http)
	var ask := slots if slots > 0 else MAX_SLOTS
	var err := http.request(_api("/api/widget/%s?slots=%d" % [data_id.strip_edges().uri_encode(), ask]), _headers())
	if err != OK:
		http.queue_free()
		push_warning("[RecoVibes] Couldn't start loading recommendations (%d)." % err)
		return
	var res: Array = await http.request_completed
	http.queue_free()
	if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] != 200:
		push_warning("[RecoVibes] Couldn't load recommendations (result %d, HTTP %d)." % [res[0], res[1]])
		return
	var parsed = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY or str(parsed.get("receipt", "")) == "":
		push_warning("[RecoVibes] Unexpected response from the server.")
		return
	# A fresh load is a fresh screen view.
	_host_seen = false
	_seen.clear()
	render(parsed)
	_track("ready")


## Draws a response from GET /api/widget/<id> into this Control (also used by tests).
func render(response: Dictionary) -> void:
	_data = response
	if str(response.get("receipt", "")) != "":
		_receipt = str(response.receipt)
	if is_instance_valid(_content):
		_content.queue_free()
		remove_child(_content)
	_content = null
	_cards.clear()
	_shown = 0
	_rendered_size = size

	var recs: Array = response.get("recommendations", []) if response.get("recommendations") is Array else []
	if response.is_empty() or response.get("paused", false) or recs.is_empty():
		rendered.emit(0)
		return

	var design: Dictionary = response.get("widget", {}) if response.get("widget") is Dictionary else {}
	var dark := theme_mode == ThemeMode.DARK or (theme_mode == ThemeMode.FROM_DASHBOARD and str(design.get("theme", "")) != "light")
	var accent_hex := str(design.get("accent", ""))
	var accent := Color.from_string(accent_hex, DEFAULT_ACCENT) if accent_hex != "" else DEFAULT_ACCENT
	var pal := _palette(dark)
	var heading: bool = not design.get("hideHeading", false)

	var room := size - Vector2(PADDING * 2, PADDING * 2)
	var fit := slots if slots > 0 else auto_slots(layout, room.x, room.y, heading, card_height, min_card_width, spacing, HEADING_HEIGHT)
	_shown = mini(fit, recs.size())

	_content = Panel.new()
	_content.name = "RecoVibes"
	_content.mouse_filter = Control.MOUSE_FILTER_PASS
	_content.add_theme_stylebox_override("panel", _box(pal.panel, 16))
	add_child(_content)
	_content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	if heading:
		var title := str(design.get("heading", ""))
		_build_heading(title if title != "" else heading_for(str(design.get("lang", ""))), pal)

	var list: BoxContainer = VBoxContainer.new() if layout == Layout.VERTICAL else HBoxContainer.new()
	list.name = "Cards"
	list.add_theme_constant_override("separation", int(spacing))
	_content.add_child(list)
	list.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	list.offset_left = PADDING
	list.offset_right = -PADDING
	list.offset_bottom = -PADDING
	list.offset_top = PADDING + (HEADING_HEIGHT + spacing if heading else 0.0)

	for i in _shown:
		_cards.append(_build_card(list, recs[i], i, pal, accent))
	rendered.emit(_shown)


func _build_heading(text: String, pal: Dictionary) -> void:
	var row := HBoxContainer.new()
	row.name = "Heading"
	_content.add_child(row)
	row.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	row.offset_left = PADDING
	row.offset_right = -PADDING
	row.offset_top = PADDING
	row.offset_bottom = PADDING + HEADING_HEIGHT
	var title := _label(text.to_upper(), 13, pal.muted, true)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(title)
	var by := LinkButton.new()
	by.name = "ByRecoVibes"
	by.text = "by RecoVibes"
	by.underline = LinkButton.UNDERLINE_MODE_ON_HOVER
	by.add_theme_font_size_override("font_size", 12)
	by.add_theme_color_override("font_color", pal.muted)
	if font:
		by.add_theme_font_override("font", font)
	by.pressed.connect(func() -> void: open_url.call(ATTRIBUTION_URL))
	row.add_child(by)


func _build_card(list: BoxContainer, rec: Dictionary, index: int, pal: Dictionary, accent: Color) -> Dictionary:
	var card := Button.new()
	card.name = "Card%d" % (index + 1)
	card.focus_mode = Control.FOCUS_NONE
	card.clip_contents = true
	for state in ["normal", "focus", "disabled"]:
		card.add_theme_stylebox_override(state, _box(pal.card, 12))
	card.add_theme_stylebox_override("hover", _box(pal.card.lerp(pal.fg, 0.06), 12))
	card.add_theme_stylebox_override("pressed", _box(pal.card.lerp(pal.fg, 0.12), 12))
	if layout == Layout.VERTICAL:
		card.custom_minimum_size.y = card_height
	else:
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.size_flags_stretch_ratio = 1.0
	card.size_flags_vertical = Control.SIZE_FILL if layout == Layout.VERTICAL else Control.SIZE_EXPAND_FILL
	list.add_child(card)

	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 12)
	card.add_child(row)
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 12
	row.offset_right = -12
	row.offset_top = 8
	row.offset_bottom = -8

	# Avatar: the name's first letter on an accent-hued circle.
	var avatar := Panel.new()
	avatar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	avatar.custom_minimum_size = Vector2(44, 44)
	avatar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var hue := fposmod(accent.h + index * 47.0 / 360.0, 1.0)
	avatar.add_theme_stylebox_override("panel", _box(Color.from_hsv(hue, maxf(accent.s, 0.45), maxf(accent.v, 0.75)), 22))
	var name_text := str(rec.get("name", "")) if str(rec.get("name", "")) != "" else str(rec.get("host", ""))
	var initial := _label(name_text.substr(0, 1).to_upper() if name_text != "" else "?", 20, Color.WHITE, true)
	initial.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	initial.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	avatar.add_child(initial)
	initial.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.add_child(avatar)

	var text := VBoxContainer.new()
	text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.alignment = BoxContainer.ALIGNMENT_CENTER
	text.add_theme_constant_override("separation", 2)
	row.add_child(text)
	var title := _label(name_text, 16, pal.fg, true)
	title.name = "Name"
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	text.add_child(title)
	var desc := str(rec.get("description", ""))
	if desc == "" and rec.get("categories") is Array:
		desc = " · ".join(PackedStringArray(rec.categories))
	if desc != "":
		var d := _label(desc, 13, pal.muted, false)
		d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		d.max_lines_visible = 2 if layout == Layout.HORIZONTAL else 1
		d.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		text.add_child(d)

	var entry := {"card": rec, "node": card, "visible_for": 0.0}
	card.pressed.connect(func() -> void: _on_card_pressed(rec))
	return entry


# ---- viewability ----

func _process(delta: float) -> void:
	if _cards.is_empty():
		return
	_tick += delta
	if _tick < 0.2:
		return
	var dt := _tick
	_tick = 0.0
	for c in _cards:
		var id := str(c.card.get("dataId", ""))
		if _seen.has(id):
			continue
		if not _focused or not is_half_visible(c.node):
			c.visible_for = 0.0  # must be one continuous second
			continue
		c.visible_for += dt
		if c.visible_for < 1.0:
			continue
		_seen[id] = true
		if not _host_seen:
			_host_seen = true
			_track("impression")
		_track("impression", id)


## True when at least half of [param node] is on screen and not see-through.
func is_half_visible(node: Control) -> bool:
	if not is_instance_valid(node) or not node.is_visible_in_tree():
		return false
	var alpha := 1.0
	var p: Node = node
	while p != null:
		if p is CanvasItem:
			alpha *= (p as CanvasItem).modulate.a * (p as CanvasItem).self_modulate.a if p == node else (p as CanvasItem).modulate.a
		p = p.get_parent()
	if alpha < 0.05:
		return false
	var view := get_viewport().get_visible_rect()
	var anc: Node = node.get_parent()
	while anc != null:
		if anc is Control and (anc as Control).clip_contents:
			view = view.intersection(_screen_rect(anc as Control))
		anc = anc.get_parent()
	return visible_fraction(_screen_rect(node), view) >= 0.5


func _screen_rect(c: Control) -> Rect2:
	return c.get_global_transform_with_canvas() * Rect2(Vector2.ZERO, c.size)


func _on_resized() -> void:
	# Re-fit when the rectangle changes size (rotation, resizing UI).
	if not _data.is_empty() and is_instance_valid(_content) and (size - _rendered_size).length_squared() > 4.0:
		render(_data)


# ---- clicks ----

func _on_card_pressed(rec: Dictionary) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if now - _last_click < 1.0:
		return  # one tap, one visit
	_last_click = now
	var http := _track("click", str(rec.get("dataId", "")), new_click_id())
	# Give the report a moment to leave before the store takes over the screen.
	if http:
		await _first_of(http.request_completed, 0.6)
	open_url.call(str(rec.get("url", "")))


func _first_of(sig: Signal, seconds: float) -> void:
	var done := [false]
	sig.connect(func(_a = null, _b = null, _c = null, _d = null) -> void: done[0] = true, CONNECT_ONE_SHOT)
	var t := 0.0
	while not done[0] and t < seconds:
		await get_tree().process_frame
		t += get_process_delta_time()


# ---- reporting ----

func _track(type: String, target := "", click_id := "") -> HTTPRequest:
	if _receipt == "":
		return null
	tracked.emit(type, target)
	var body := {
		"type": type,
		"sourceDataId": data_id.strip_edges(),
		"widgetSlots": _shown,
		"widgetVersion": WIDGET_VERSION,
		"receipt": _receipt,
		# Views in the editor never earn points.
		"automated": OS.has_feature("editor"),
		"trusted": true,
	}
	if target != "":
		body["targetDataId"] = target
	if click_id != "":
		body["clickId"] = click_id
	return _send(JSON.stringify(body), 0)


func _send(json: String, attempt: int) -> HTTPRequest:
	if not is_inside_tree():
		return null
	var http := HTTPRequest.new()
	http.timeout = 10.0
	add_child(http)
	http.request_completed.connect(func(result: int, code: int, _h, _b) -> void:
		http.queue_free()
		if attempt < 2 and (result != HTTPRequest.RESULT_SUCCESS or code >= 500 or code == 429) and is_inside_tree():
			await get_tree().create_timer((attempt + 1) * 2.0).timeout
			_send(json, attempt + 1)
	, CONNECT_ONE_SHOT)
	var headers := _headers()
	headers.append("Content-Type: application/json")
	http.request(_api("/api/track"), headers, HTTPClient.METHOD_POST, json)
	return http


func _headers() -> PackedStringArray:
	var v := Engine.get_version_info()
	# Our own user agent tells the server this is an app, not a browser.
	return PackedStringArray([
		"User-Agent: RecoVibesGodot/%s (%s; Godot %s)" % [PACKAGE_VERSION, OS.get_name(), v.string],
		"Accept-Language: " + (OS.get_locale_language() if OS.get_locale_language() != "" else "en"),
	])


func _api(path: String) -> String:
	var base := api_base.strip_edges().trim_suffix("/")
	return (base if base != "" else "https://api.recovibes.com") + path


# ---- UI helpers ----

func _palette(dark: bool) -> Dictionary:
	if dark:
		return {"panel": Color("#121215"), "card": Color("#1e1e23"), "fg": Color("#f2f2f4"), "muted": Color("#9a9aa6")}
	return {"panel": Color("#f3f3f5"), "card": Color.WHITE, "fg": Color("#141418"), "muted": Color("#6b6b76")}


func _box(color: Color, radius: int) -> StyleBoxFlat:
	var b := StyleBoxFlat.new()
	b.bg_color = color
	b.set_corner_radius_all(radius)
	b.anti_aliasing = true
	return b


func _label(text: String, size_px: int, color: Color, bold: bool) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", size_px)
	l.add_theme_color_override("font_color", color)
	var base: Font = font if font else ThemeDB.fallback_font
	if bold:
		var v := FontVariation.new()
		v.base_font = base
		v.variation_embolden = 0.7
		l.add_theme_font_override("font", v)
	elif font:
		l.add_theme_font_override("font", font)
	return l
