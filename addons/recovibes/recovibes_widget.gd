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
const PACKAGE_VERSION := "1.2.1"
const MAX_SLOTS := 12
const ATTRIBUTION_URL := "https://recovibes.com/?utm_source=godot&utm_medium=attribution"
const DEFAULT_ACCENT := Color("#7e7eff")

# FROM_DASHBOARD is 0, the value of the old default (VERTICAL), so existing scenes follow the dashboard.
enum Layout { FROM_DASHBOARD, HORIZONTAL, VERTICAL }
enum ThemeMode { FROM_DASHBOARD, LIGHT, DARK }

## Your app's ID from the RecoVibes dashboard (Install tab), e.g. rv_ab12cd34.
@export var data_id := ""
## How many recommendations to show. 0 = as many as fit.
@export_range(0, 12) var slots := 0
## FROM_DASHBOARD follows the design you picked in the dashboard. VERTICAL
## forces one column, HORIZONTAL one row.
@export var layout := Layout.FROM_DASHBOARD
## FROM_DASHBOARD uses the theme from your RecoVibes design (dark when it's Auto).
@export var theme_mode := ThemeMode.FROM_DASHBOARD
## Optional: your game's font.
@export var font: Font
## Optional: a monospaced font for the Terminal template. Empty = the system's.
@export var mono_font: Font
## Size multiplier for everything (text, spacing, cards). 0 = Auto: sized in
## real points for the device, whatever your base resolution. Don't scale the
## node itself instead - text would be drawn small and stretched (blurry).
@export_range(0.0, 6.0, 0.05) var ui_scale := 0.0
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
var _rendered_scale := 1.0
var _k := 1.0  # the scale in use while rendering
var _st: Dictionary = {}  # the style being drawn
var _system_mono: SystemFont
var _tick := 0.0
var _last_click := -10.0
var _focused := true


static func auto_slots(lay: int, width: float, height: float, heading: bool, card_h: float, min_w: float, gap: float, heading_h: float) -> int:
	var n: int
	if lay != Layout.HORIZONTAL:
		var room := height - (heading_h + gap if heading else 0.0)
		n = floori((room + gap) / (card_h + gap))
	else:
		n = floori((width + gap) / (min_w + gap))
	return clampi(n, 1, MAX_SLOTS)


## Multiplier so one design unit is one point (1/160 inch) on screen: screen
## pixels per point over screen pixels per canvas unit. At least 1, at most 6.
static func auto_scale(dpi: float, pixels_per_unit: float) -> float:
	if dpi <= 0.0 or pixels_per_unit <= 0.0:
		return 1.0
	return clampf(dpi / 160.0 / pixels_per_unit, 1.0, 6.0)


## The multiplier in use: ui_scale when set, else auto from the screen.
func effective_scale() -> float:
	if ui_scale > 0.0:
		return ui_scale
	if not is_inside_tree() or DisplayServer.get_name() == "headless":
		return 1.0
	return auto_scale(DisplayServer.screen_get_dpi(), get_viewport().get_screen_transform().get_scale().x)


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


## The classic look, for servers that don't send a style yet.
static func classic_style(design: Dictionary) -> Dictionary:
	var accent := str(design.get("accent", ""))
	accent = (accent + "ff") if accent.length() == 7 else "#7e7effff"
	var t := str(design.get("theme", ""))
	return {
		"version": 1, "template": "classic", "theme": t if t == "light" or t == "dark" else "", "slots": 0,
		"layout": "grid", "maxColumns": 4, "minWidth": 180, "itemHeight": 66, "gap": 10, "rowGap": 10, "padding": 14, "itemPadX": 14,
		"radius": 10, "panelRadius": 14, "cardFill": true, "border": true, "divider": false, "avatar": false, "avatarSize": 0, "avatarRadius": 0,
		"nameSize": 15, "nameBold": true, "nameAccent": false, "descShow": true, "descSize": 12.5, "descLines": 2, "descInline": false,
		"prefix": "", "suffix": "", "mono": false, "headingShow": not design.get("hideHeading", false), "headingText": str(design.get("heading", "")),
		"headingSize": 12, "headingUppercase": true, "headingBar": false,
		"light": {"panel": "#f5f5f7ff", "card": "#ffffffff", "line": "#0000001f", "text": "#17171cff", "muted": "#17171cad", "accent": accent, "bar": "#eaeef2ff", "pressed": "#0000000d"},
		"dark": {"panel": "#111116ff", "card": "#1b1b22ff", "line": "#ffffff24", "text": "#f2f2f5ff", "muted": "#f2f2f5ad", "accent": accent, "bar": "#161b22ff", "pressed": "#ffffff14"},
	}


## Draws a response from GET /api/widget/<id> into this Control (also used by tests).
## The server sends the dashboard design as drawing instructions ("native"),
## so a new template or tweak reaches games without a new addon.
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
	_k = effective_scale()
	_rendered_scale = _k

	var recs: Array = response.get("recommendations", []) if response.get("recommendations") is Array else []
	if response.is_empty() or response.get("paused", false) or recs.is_empty():
		rendered.emit(0)
		return

	var design: Dictionary = response.get("widget", {}) if response.get("widget") is Dictionary else {}
	var native = response.get("native")
	_st = classic_style(design)
	if native is Dictionary and int(native.get("version", 0)) >= 1:
		_st.merge(native, true)
	var dark := theme_mode == ThemeMode.DARK or (theme_mode == ThemeMode.FROM_DASHBOARD and str(_st.theme) != "light")
	var pal := _palette(_st.dark if dark else _st.light)

	_content = Panel.new()
	_content.name = "RecoVibes"
	_content.mouse_filter = Control.MOUSE_FILTER_PASS
	_content.add_theme_stylebox_override("panel", _box(pal.panel, _f("panelRadius")))
	add_child(_content)
	_content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var pad := _f("padding") * _k
	var top := pad
	if _st.headingShow:
		var title := str(_st.headingText)
		if title == "":
			title = heading_for(str(design.get("lang", "")))
		top = _build_heading_bar(title, pal) + pad * 0.7 if _st.headingBar else _build_heading(title, pal, pad)
	var area := Rect2(pad, top, size.x - pad * 2, maxf(0.0, size.y - top - pad))
	var limit := mini(slots if slots > 0 else (int(_st.slots) if int(_st.slots) > 0 else MAX_SLOTS), recs.size())
	if str(_st.layout) == "chips":
		_layout_chips(recs, limit, area, pal)
	else:
		_layout_grid(recs, limit, area, pal)
	_shown = _cards.size()
	# The panel ends under the last row, like on the web, instead of filling
	# a taller rectangle with empty space.
	var used := 0.0
	for c in _cards:
		used = maxf(used, c.node.position.y + c.node.size.y)
	if used > 0.0 and used + pad < size.y:
		_content.anchor_bottom = 0.0
		_content.offset_bottom = used + pad
	rendered.emit(_shown)


func _f(key: String) -> float:
	return float(_st.get(key, 0.0))


# Title on the left, attribution on the right. Returns where items start.
func _build_heading(text: String, pal: Dictionary, pad: float) -> float:
	var h := maxf(20.0, _f("headingSize") * 1.6) * _k
	var by := LinkButton.new()
	by.name = "ByRecoVibes"
	by.text = "by RecoVibes"
	by.underline = LinkButton.UNDERLINE_MODE_ON_HOVER
	by.add_theme_font_size_override("font_size", _px(_f("headingSize") - 1))
	by.add_theme_color_override("font_color", pal.muted)
	by.add_theme_font_override("font", _font(false, _st.mono))
	by.pressed.connect(func() -> void: open_url.call(ATTRIBUTION_URL))
	_content.add_child(by)
	var by_w := by.get_combined_minimum_size().x
	by.position = Vector2(size.x - pad - by_w, pad + (h - by.get_combined_minimum_size().y) / 2)
	var title := _label(text.to_upper() if _st.headingUppercase else text, _f("headingSize"), pal.muted, true, _st.mono)
	title.name = "Title"
	_place(_content, title, pad, pad, size.x - pad * 2 - by_w - 8 * _k, h)
	return pad + h + 10.0 * _k


# A window title bar with traffic lights (terminal). Returns its height.
func _build_heading_bar(text: String, pal: Dictionary) -> float:
	var h := (_f("headingSize") + 18.0) * _k
	var bar := Panel.new()
	bar.name = "HeadingBar"
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var box := _box(pal.bar, _f("panelRadius"))
	box.corner_radius_bottom_left = 0
	box.corner_radius_bottom_right = 0
	box.border_color = pal.line
	box.border_width_bottom = maxi(1, roundi(_k))
	bar.add_theme_stylebox_override("panel", box)
	_place(_content, bar, 0, 0, size.x, h)
	var dot := 9.0 * _k
	var x := 12.0 * _k
	for hex in ["#ff5f57", "#febc2e", "#28c840"]:
		var d := Panel.new()
		d.mouse_filter = Control.MOUSE_FILTER_IGNORE
		d.add_theme_stylebox_override("panel", _box(Color(hex), 999))
		_place(bar, d, x, (h - dot) / 2, dot, dot)
		x += dot + 5.0 * _k
	var t := _label(text.to_upper() if _st.headingUppercase else text, _f("headingSize"), pal.muted, false, _st.mono)
	t.name = "Title"
	_place(bar, t, x + 24.0 * _k, 0, size.x - x - 36.0 * _k, h)
	return h


func _layout_grid(recs: Array, limit: int, area: Rect2, pal: Dictionary) -> void:
	var item_h := _f("itemHeight") * _k
	var gap := _f("gap") * _k
	var row_gap := _f("rowGap") * _k
	var max_cols := maxi(1, int(_st.maxColumns))
	var cols := max_cols
	if layout == Layout.VERTICAL:
		cols = 1
	elif _f("minWidth") > 0:
		cols = clampi(floori((area.size.x + gap) / (_f("minWidth") * _k + gap)), 1, max_cols)
	var rows := 1 if layout == Layout.HORIZONTAL else maxi(1, floori((area.size.y + row_gap) / (item_h + row_gap)))
	var n := limit if (slots > 0 or int(_st.slots) > 0) else mini(limit, rows * cols)
	if layout == Layout.HORIZONTAL:
		cols = maxi(1, n)
	var cell_w := (area.size.x - gap * (cols - 1)) / cols
	for i in n:
		var col := i % cols
		var row := i / cols
		_cards.append(_build_item(recs[i], i, pal, area.position.x + col * (cell_w + gap), area.position.y + row * (item_h + row_gap), cell_w, item_h))


func _layout_chips(recs: Array, limit: int, area: Rect2, pal: Dictionary) -> void:
	var h := _f("itemHeight") * _k
	var gap := _f("gap") * _k
	var row_gap := _f("rowGap") * _k
	var lines := 1 if layout == Layout.HORIZONTAL else maxi(1, floori((area.size.y + row_gap) / (h + row_gap)))
	var x := 0.0
	var y := 0.0
	var line := 0
	for i in limit:
		var name_text := _display_name(recs[i])
		var w := minf(area.size.x, _f("itemPadX") * _k * 2 + (_f("avatarSize") * _k + 8.0 * _k if _st.avatar else 0.0) + _text_width(name_text, _f("nameSize"), _st.nameBold, _st.mono) + 2.0 * _k)
		if x > 0 and x + w > area.size.x:
			line += 1
			if line >= lines:
				break
			x = 0.0
			y += h + row_gap
		_cards.append(_build_item(recs[i], i, pal, area.position.x + x, area.position.y + y, w, h))
		x += w + gap


func _build_item(rec: Dictionary, index: int, pal: Dictionary, x: float, y: float, w: float, h: float) -> Dictionary:
	var card := Button.new()
	card.name = "Card%d" % (index + 1)
	card.focus_mode = Control.FOCUS_NONE
	card.clip_contents = true
	var fill: Color = pal.card if _st.cardFill else Color(0, 0, 0, 0)
	for state in ["normal", "focus", "disabled", "hover", "pressed"]:
		var bg := fill
		if state == "hover" or state == "pressed":
			bg = _over(fill, pal.pressed, 0.6 if state == "hover" else 1.0)
		var box := _box(bg, _f("radius"))
		if _st.border:
			box.border_color = pal.line
			box.set_border_width_all(maxi(1, roundi(_k)))
		elif _st.divider:
			box.set_corner_radius_all(0)
			box.border_color = pal.line
			box.border_width_bottom = maxi(1, roundi(_k))
		card.add_theme_stylebox_override(state, box)
	_place(_content, card, x, y, w, h)

	var px := _f("itemPadX") * _k
	var cx := px
	var right := w - px
	if str(_st.prefix) != "":
		var pre := _label(str(_st.prefix), _f("nameSize"), pal.accent, false, _st.mono)
		pre.name = "Prefix"
		var pw := _text_width(str(_st.prefix), _f("nameSize"), false, _st.mono)
		_place(card, pre, cx, 0, pw + 1, h)
		cx += pw + 10.0 * _k
	if str(_st.suffix) != "":
		var suf := _label(str(_st.suffix), _f("nameSize"), pal.muted, false, _st.mono)
		suf.name = "Suffix"
		var sw := _text_width(str(_st.suffix), _f("nameSize"), false, _st.mono)
		_place(card, suf, right - sw - 1, 0, sw + 1, h)
		right -= sw + 8.0 * _k
	var name_text := _display_name(rec)
	if _st.avatar:
		var a := _f("avatarSize") * _k
		var av := Panel.new()
		av.name = "Avatar"
		av.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var hue := fposmod(pal.accent.h + index * 47.0 / 360.0, 1.0)
		av.add_theme_stylebox_override("panel", _box(Color.from_hsv(hue, maxf(pal.accent.s, 0.45), maxf(pal.accent.v, 0.75)), _f("avatarRadius")))
		_place(card, av, cx, (h - a) / 2, a, a)
		var initial := _label(name_text.substr(0, 1).to_upper() if name_text != "" else "?", _f("avatarSize") * 0.43, Color.WHITE, true, false)
		initial.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_place(av, initial, 0, 0, a, a)
		cx += a + (8.0 if str(_st.layout) == "chips" else 12.0) * _k

	var text_w := maxf(0.0, right - cx)
	var desc := str(rec.get("description", ""))
	if desc == "" and rec.get("categories") is Array:
		desc = " · ".join(PackedStringArray(rec.categories))
	var show_desc: bool = _st.descShow and desc != ""
	var title := _label(name_text, _f("nameSize"), pal.accent if _st.nameAccent else pal.text, _st.nameBold, _st.mono)
	title.name = "Name"
	if _st.descInline or not show_desc:
		var name_w := minf(_text_width(name_text, _f("nameSize"), _st.nameBold, _st.mono) + 2.0 * _k, text_w * 0.65) if show_desc else text_w
		_place(card, title, cx, 0, name_w, h)
		if show_desc:
			var dx := cx + name_w + 10.0 * _k
			var d := _label(desc, _f("descSize"), pal.muted, false, _st.mono)
			d.name = "Description"
			_place(card, d, dx, 0, maxf(0.0, right - dx), h)
	else:
		var lines := maxi(1, int(_st.descLines))
		var name_h := _f("nameSize") * 1.35 * _k
		var desc_h := _f("descSize") * 1.35 * _k
		var ty := maxf(0.0, (h - (name_h + 3.0 * _k + desc_h * lines)) / 2)
		_place(card, title, cx, ty, text_w, name_h)
		var d := _label(desc, _f("descSize"), pal.muted, false, _st.mono)
		d.name = "Description"
		d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		d.max_lines_visible = lines
		d.clip_text = false  # the line limit cuts it
		d.add_theme_constant_override("line_spacing", 0)
		d.vertical_alignment = VERTICAL_ALIGNMENT_TOP
		_place(card, d, cx, ty + name_h + 3.0 * _k, text_w, desc_h * lines)

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
	# Re-fit when the rectangle or the scale changes (rotation, resizing UI).
	if not _data.is_empty() and is_instance_valid(_content) and ((size - _rendered_size).length_squared() > 4.0 or absf(effective_scale() - _rendered_scale) > 0.05):
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

func _px(points: float) -> int:
	return maxi(1, roundi(points * _k))


static func _display_name(rec: Dictionary) -> String:
	var n := str(rec.get("name", ""))
	return n if n != "" else str(rec.get("host", ""))


func _palette(p: Dictionary) -> Dictionary:
	var out := {}
	for key in ["panel", "card", "line", "text", "muted", "accent", "bar", "pressed"]:
		out[key] = Color.from_string(str(p.get(key, "")), Color.GRAY)
	return out


# Lays a color over another, like a translucent layer.
static func _over(base: Color, layer: Color, amount: float) -> Color:
	var a := layer.a * amount
	return Color(lerpf(base.r, layer.r, a), lerpf(base.g, layer.g, a), lerpf(base.b, layer.b, a), maxf(base.a, a))


func _box(color: Color, radius_pt: float) -> StyleBoxFlat:
	var b := StyleBoxFlat.new()
	b.bg_color = color
	b.set_corner_radius_all(roundi(radius_pt * _k))  # Godot shrinks radii that don't fit: 999 is a pill
	b.anti_aliasing = true
	return b


# Positions node at (x, y) inside parent, w × h.
func _place(parent: Control, node: Control, x: float, y: float, w: float, h: float) -> void:
	parent.add_child(node)
	node.position = Vector2(x, y)
	node.size = Vector2(maxf(0.0, w), maxf(0.0, h))


func _font(bold: bool, mono: bool) -> Font:
	var base: Font = font if font else ThemeDB.fallback_font
	if mono:
		if mono_font:
			base = mono_font
		else:
			if _system_mono == null:
				_system_mono = SystemFont.new()
				_system_mono.font_names = PackedStringArray(["Menlo", "SF Mono", "Consolas", "DejaVu Sans Mono", "Roboto Mono", "monospace"])
			base = _system_mono
	if not bold:
		return base
	var v := FontVariation.new()
	v.base_font = base
	v.variation_embolden = 0.7
	return v


func _text_width(text: String, size_pt: float, bold: bool, mono: bool) -> float:
	return _font(bold, mono).get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, _px(size_pt)).x


func _label(text: String, size_pt: float, color: Color, bold: bool, mono: bool) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.clip_text = true
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", _px(size_pt))  # drawn at its real size: sharp
	l.add_theme_color_override("font_color", color)
	l.add_theme_font_override("font", _font(bold, mono))
	return l
