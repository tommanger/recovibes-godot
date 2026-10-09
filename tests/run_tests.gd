extends SceneTree
# Headless tests: godot --headless --path . --script res://tests/run_tests.gd
# Set RECOVIBES_TEST_API and RECOVIBES_TEST_DATA_ID to also run against a server.

var failures := 0
var opened: Array = []
var tracked: Array = []


func _initialize() -> void:
	_run.call_deferred()


func check(cond: bool, what: String) -> void:
	if cond:
		print("  ok   ", what)
	else:
		failures += 1
		printerr("  FAIL ", what)


func sample(n: int, theme := "") -> Dictionary:
	var recs := []
	for i in n:
		recs.append({"dataId": "rv_%d" % (i + 1), "name": "Game %d" % (i + 1), "url": "https://example.com/%d" % (i + 1), "description": "A fine game"})
	return {"receipt": "test-receipt", "recommendations": recs, "widget": {"theme": theme, "lang": "en"}}


func styled(n: int, tune: Dictionary) -> Dictionary:
	var r := sample(n)
	r.recommendations[1].name = "A much longer game name"
	var st := RecoVibesWidget.classic_style({})
	st.merge(tune, true)
	r["native"] = st
	return r


func make_widget(w := 600.0, h := 400.0) -> RecoVibesWidget:
	var widget := RecoVibesWidget.new()
	widget.api_base = "http://127.0.0.1:9"  # nothing listens: reports go nowhere
	widget.position = Vector2.ZERO
	widget.size = Vector2(w, h)
	widget.open_url = func(url: String) -> void: opened.append(url)
	widget.tracked.connect(func(type: String, target: String) -> void: tracked.append(type + ":" + target))
	root.add_child(widget)  # no data_id: no network load, tests render samples
	return widget


func wait(seconds: float) -> void:
	await create_timer(seconds).timeout


func reset(widget: RecoVibesWidget) -> void:
	widget.queue_free()
	await process_frame
	opened.clear()
	tracked.clear()


func _run() -> void:
	root.size = Vector2i(1080, 1920)
	print("pure helpers")
	check(RecoVibesWidget.auto_slots(RecoVibesWidget.Layout.VERTICAL, 600, 376, true, 76, 200, 10, 20) == 4, "vertical auto slots")
	check(RecoVibesWidget.auto_slots(RecoVibesWidget.Layout.HORIZONTAL, 836, 100, true, 76, 200, 10, 20) == 4, "horizontal auto slots")
	check(RecoVibesWidget.auto_slots(RecoVibesWidget.Layout.VERTICAL, 600, 10, true, 76, 200, 10, 20) == 1, "at least one")
	check(is_equal_approx(RecoVibesWidget.visible_fraction(Rect2(-50, 10, 100, 100), Rect2(0, 0, 1000, 1000)), 0.5), "half visible")
	check(RecoVibesWidget.visible_fraction(Rect2(2000, 0, 100, 100), Rect2(0, 0, 1000, 1000)) == 0.0, "offscreen")
	var id := RecoVibesWidget.new_click_id()
	check(id.length() == 32 and id != RecoVibesWidget.new_click_id(), "fresh 32-char click ids")

	print("fills the space and counts one visible second")
	var w := make_widget()
	var counts := [-1]
	w.rendered.connect(func(n: int) -> void: counts[0] = n)
	await process_frame
	w.render(sample(8))
	await process_frame
	check(counts[0] == 8, "3 columns x 4 rows fit in 600x400: all 8 shown (got %d)" % counts[0])
	var names := []
	for n in w.find_children("Name", "Label", true, false):
		names.append(n.text)
	check(names.size() == counts[0] and names[0] == "Game 1", "card names drawn")
	await wait(0.5)
	check(not tracked.any(func(t): return t.begins_with("impression")), "nothing counted before a second")
	await wait(1.0)
	check(tracked.count("impression:") == 1, "one widget view")
	check(tracked.count("impression:rv_1") == 1, "first card counted")
	await wait(1.0)
	check(tracked.count("impression:rv_1") == 1, "counted once per screen view")
	await reset(w)

	print("hidden or offscreen cards don't count")
	w = make_widget()
	w.modulate.a = 0.0
	w.render(sample(3))
	await wait(1.5)
	check(not tracked.any(func(t): return t.begins_with("impression")), "transparent widget not counted")
	await reset(w)
	w = make_widget()
	w.position = Vector2(5000, 0)
	w.render(sample(3))
	await wait(1.5)
	check(not tracked.any(func(t): return t.begins_with("impression")), "offscreen widget not counted")
	await reset(w)

	print("tap reports the click, then opens the store")
	w = make_widget()
	w.render(sample(3))
	await process_frame
	var card: Button = w.find_child("Card2", true, false)
	card.pressed.emit()
	card.pressed.emit()  # a double tap is one visit
	await wait(1.0)
	check(tracked.filter(func(t): return t.begins_with("click")) == ["click:rv_2"], "one click reported")
	check(opened == ["https://example.com/2"], "store page opened (got %s)" % [opened])
	await reset(w)

	print("scale draws text bigger instead of stretching it")
	check(is_equal_approx(RecoVibesWidget.auto_scale(480, 1.0), 3.0), "auto scale: 480 dpi, 1:1 canvas")
	check(RecoVibesWidget.auto_scale(96, 1.0) == 1.0 and RecoVibesWidget.auto_scale(0, 1.0) == 1.0, "auto scale never below 1")
	w = make_widget()
	w.slots = 1
	w.render(sample(1))
	await process_frame
	var base_font: int = (w.find_child("Name", true, false) as Label).get_theme_font_size("font_size")
	w.ui_scale = 2.5
	w.render(sample(1))
	await process_frame
	var scaled: Label = w.find_child("Name", true, false)
	check(scaled.get_theme_font_size("font_size") == roundi(base_font * 2.5), "font size scaled (%d -> %d)" % [base_font, scaled.get_theme_font_size("font_size")])
	check(w.scale == Vector2.ONE, "node itself not scaled")
	await reset(w)

	print("paused, empty, fixed slots, theme")
	w = make_widget()
	var paused := sample(3)
	paused["paused"] = true
	w.render(paused)
	check(w.find_children("Card*", "Button", true, false).is_empty(), "paused shows nothing")
	w.render(sample(0))
	check(w.find_children("Card*", "Button", true, false).is_empty(), "empty shows nothing")
	w.slots = 2
	w.layout = RecoVibesWidget.Layout.HORIZONTAL
	w.render(sample(5, "light"))
	check(w.find_children("Card*", "Button", true, false).size() == 2, "fixed slots")
	var panel: Panel = w.find_child("RecoVibes", true, false)
	check((panel.get_theme_stylebox("panel") as StyleBoxFlat).bg_color.r > 0.5, "light theme from the dashboard")
	await reset(w)

	print("the panel ends under the last row")
	w = make_widget()
	w.render(styled(2, {"slots": 1}))
	var pnl: Panel = w.find_child("RecoVibes", true, false)
	check(pnl.size.y < w.size.y - 50, "no empty panel below the cards (%d of %d)" % [pnl.size.y, w.size.y])
	await reset(w)

	print("draws the dashboard's templates")
	w = make_widget()
	w.render(styled(8, {"slots": 3}))
	var cs := w.find_children("Card*", "Button", true, false)
	check(cs.size() == 3, "the dashboard's slot count")
	check(is_equal_approx(cs[0].position.y, cs[2].position.y), "three 180-wide columns in 600")

	w.render(styled(6, {"template": "pills", "layout": "chips", "maxColumns": 0, "itemHeight": 36, "radius": 999, "gap": 8, "rowGap": 8,
		"avatar": true, "avatarSize": 24, "avatarRadius": 12, "nameSize": 13, "nameBold": false, "descShow": false}))
	cs = w.find_children("Card*", "Button", true, false)
	check(w.find_children("Description", "Label", true, false).is_empty(), "pills: no description")
	check(cs[1].size.x > cs[0].size.x + 40, "pills: as wide as the name (%d vs %d)" % [cs[1].size.x, cs[0].size.x])
	check(is_equal_approx(cs[0].position.y, cs[1].position.y), "pills: share a line")
	check(is_equal_approx(cs[0].size.y, 36.0), "pills: 36 high")
	check(w.find_children("Avatar", "Panel", true, false).size() == cs.size(), "pills: an avatar each")

	w.render(styled(4, {"template": "terminal", "maxColumns": 1, "minWidth": 0, "itemHeight": 24, "gap": 0, "rowGap": 0, "itemPadX": 0,
		"cardFill": false, "border": false, "nameAccent": true, "nameBold": false, "descInline": true, "descLines": 1,
		"prefix": "→", "mono": true, "headingBar": true, "headingUppercase": false}))
	cs = w.find_children("Card*", "Button", true, false)
	check(w.find_child("HeadingBar", true, false) != null, "terminal: title bar")
	check(cs.size() > 1 and cs.all(func(c): return is_equal_approx(c.position.x, cs[0].position.x)), "terminal: one column")
	check(cs.all(func(c): return c.find_child("Prefix", false, false) != null), "terminal: prefixes")
	check((cs[0].get_theme_stylebox("normal") as StyleBoxFlat).bg_color.a == 0.0, "terminal: no card background")

	w.render(styled(4, {"template": "minimal", "maxColumns": 3, "minWidth": 260, "itemHeight": 41, "gap": 28, "rowGap": 0, "itemPadX": 2,
		"cardFill": false, "border": false, "divider": true, "descInline": true, "descLines": 1, "suffix": "↗"}))
	cs = w.find_children("Card*", "Button", true, false)
	check(cs.all(func(c): return c.find_child("Suffix", false, false) != null and (c.get_theme_stylebox("normal") as StyleBoxFlat).border_width_bottom > 0), "minimal: dividers and arrows")
	check(is_equal_approx(cs[0].position.y, cs[1].position.y), "minimal: two columns in 600")
	await reset(w)

	var api := OS.get_environment("RECOVIBES_TEST_API")
	var data_id := OS.get_environment("RECOVIBES_TEST_DATA_ID")
	if api != "" and data_id != "":
		print("end to end against ", api)
		w = RecoVibesWidget.new()
		w.api_base = api
		w.data_id = data_id
		w.size = Vector2(600, 400)
		w.open_url = func(url: String) -> void: opened.append(url)
		w.tracked.connect(func(type: String, target: String) -> void: tracked.append(type + ":" + target))
		counts[0] = -1
		w.rendered.connect(func(n: int) -> void: counts[0] = n)
		root.add_child(w)
		for i in 100:
			if counts[0] >= 0:
				break
			await wait(0.1)
		check(counts[0] > 0, "recommendations loaded from the server (%d)" % counts[0])
		await wait(1.6)
		check(tracked.has("ready:") and tracked.any(func(t): return t.begins_with("impression:rv_")), "ready and card views reported")
		(w.find_child("Card1", true, false) as Button).pressed.emit()
		await wait(1.5)
		check(opened.size() == 1, "card opened %s" % [opened])
		await wait(1.0)
	else:
		print("(end-to-end test skipped: RECOVIBES_TEST_API / RECOVIBES_TEST_DATA_ID not set)")

	print("FAILURES: ", failures)
	quit(1 if failures > 0 else 0)
