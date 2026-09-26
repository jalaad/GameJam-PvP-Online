extends Control
## Start screen: play with controllers on this screen, or phone vs phone online.

const ARENA_SCENE := "res://scenes/main.tscn"

var _home: Control
var _join: Control
var _code_label: Label
var _join_error: Label
var _code := ""


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color("#0b0d12")
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	_home = _build_home()
	_join = _build_join()
	_show(_home)
	# Opened from an invite link (?join=CODE): go straight in.
	if Session.link_code.length() == 4:
		_code = Session.link_code
		Session.link_code = ""
		_start_online(Session.Mode.ONLINE_GUEST, _code)
	elif Session.link_code != "":
		Session.link_code = ""
		_open_join()


func _unhandled_input(event: InputEvent) -> void:
	if not _join.visible or not (event is InputEventKey and event.pressed):
		return
	var key := event as InputEventKey
	if key.keycode == KEY_BACKSPACE:
		_type("<")
	elif key.keycode == KEY_ENTER or key.keycode == KEY_KP_ENTER:
		_try_join()
	elif key.keycode == KEY_ESCAPE:
		_show(_home)
	elif key.unicode > 0:
		_type(String.chr(key.unicode))


func _show(page: Control) -> void:
	_home.visible = page == _home
	_join.visible = page == _join


func _start_local() -> void:
	Session.mode = Session.Mode.LOCAL
	Session.join_code = ""
	get_tree().change_scene_to_file(ARENA_SCENE)


func _start_online(mode: Session.Mode, code := "") -> void:
	_go_fullscreen()
	Session.mode = mode
	Session.join_code = code
	get_tree().change_scene_to_file(ARENA_SCENE)


## Phones: use the whole screen (browsers only allow this from a tap, which this is).
func _go_fullscreen() -> void:
	if OS.has_feature("web") and DisplayServer.is_touchscreen_available():
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)


func _open_join() -> void:
	_join_error.text = ""
	_refresh_code()
	_show(_join)


func _type(ch: String) -> void:
	if ch == "<":
		_code = _code.left(-1)
	else:
		_code = Session.clean_code(_code + ch)
	_join_error.text = ""
	_refresh_code()


func _refresh_code() -> void:
	var shown := ""
	for i in 4:
		shown += (_code[i] if i < _code.length() else "_") + (" " if i < 3 else "")
	_code_label.text = shown


func _try_join() -> void:
	if _code.length() < 4:
		_join_error.text = "The code has 4 characters."
		return
	_start_online(Session.Mode.ONLINE_GUEST, _code)


# --- Layout -------------------------------------------------------------------

func _page() -> VBoxContainer:
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 14)
	center.add_child(col)
	return col


func _label(text: String, size: int, color := Color("#e8ecf4")) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


func _button(text: String, size: Vector2, font_size: int, color: Color, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = size
	b.add_theme_font_size_override("font_size", font_size)
	for state in ["normal", "hover", "pressed", "focus"]:
		var sb := StyleBoxFlat.new()
		sb.bg_color = color.darkened(0.55) if state != "pressed" else color.darkened(0.25)
		sb.border_color = color
		sb.set_border_width_all(2)
		sb.set_corner_radius_all(10)
		b.add_theme_stylebox_override(state, sb)
	b.pressed.connect(on_press)
	return b


func _build_home() -> Control:
	var col := _page()
	col.get_parent().name = "Home"
	col.add_child(_label("PvP Phone Arena", 52))
	col.add_child(_label("Two fighters, one arena. Pick how you want to play.", 20, Color("#8a93a6")))
	if Session.notice != "":
		col.add_child(_label(Session.notice, 20, Color("#ff6b6b")))
		Session.notice = ""
	col.add_child(Control.new())

	var online := _button("Create online match", Vector2(560, 72), 28, Color("#f72585"),
			func() -> void: _start_online(Session.Mode.ONLINE_HOST))
	col.add_child(online)
	col.add_child(_button("Join online match", Vector2(560, 72), 28, Color("#4cc9f0"), _open_join))
	col.add_child(_label("Online: each player uses their own phone (or computer) with on-screen controls.", 16, Color("#6b7489")))
	col.add_child(Control.new())
	col.add_child(_button("Play on this screen", Vector2(560, 60), 22, Color("#8a93a6"), _start_local))
	col.add_child(_label("This screen shows the arena; players scan a QR code to use their phones as controllers,\nor share the keyboard.", 16, Color("#6b7489")))
	return col.get_parent()


func _build_join() -> Control:
	var col := _page()
	col.get_parent().name = "Join"
	col.add_theme_constant_override("separation", 10)
	col.add_child(_label("Enter your friend's match code", 26))
	_code_label = _label("_ _ _ _", 56, Color("#4cc9f0"))
	col.add_child(_code_label)

	var grid := GridContainer.new()
	grid.columns = 8
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	for ch in PhoneControllerServer.CODE_CHARS:
		var key := ch
		grid.add_child(_button(key, Vector2(76, 64), 28, Color("#4a5268"), func() -> void: _type(key)))
	var grid_center := CenterContainer.new()
	grid_center.add_child(grid)
	col.add_child(grid_center)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	row.add_child(_button("Back", Vector2(150, 60), 22, Color("#8a93a6"), func() -> void: _show(_home)))
	row.add_child(_button("DEL", Vector2(110, 60), 22, Color("#8a93a6"), func() -> void: _type("<")))
	row.add_child(_button("JOIN", Vector2(220, 60), 26, Color("#4cc9f0"), _try_join))
	col.add_child(row)
	_join_error = _label("", 18, Color("#ff6b6b"))
	col.add_child(_join_error)
	return col.get_parent()
