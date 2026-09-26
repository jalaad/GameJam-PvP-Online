class_name TouchControls
extends Control
## On-screen controls for playing on the phone itself: a joystick (put your thumb down anywhere
## on the left half of the screen) and four action buttons. Multi-touch, so you can move and
## attack at once. Without a touchscreen the mouse works too (handy on desktop).
##
## Where things go is set by the arena (place()), so the controls sit in their own panels next
## to or below the arena instead of covering it.

signal button_down(button: StringName)

## Button layout around the cluster centre, in units of `spacing`.
const BUTTONS := {
	&"attack": {"dir": Vector2(1, 0), "label": "ATK", "color": Color("#ff5d73")},
	&"shoot": {"dir": Vector2(0, -1), "label": "SHOOT", "color": Color("#ffb703")},
	&"block": {"dir": Vector2(-1, 0), "label": "BLOCK", "color": Color("#8ecae6")},
	&"dash": {"dir": Vector2(0, 1), "label": "DASH", "color": Color("#b8f35a")},
}

## Joystick, each axis -1..1, y+ is down.
var stick := Vector2.ZERO
## Presses so far per button (never reset), for clients that send counts.
var press_counts := {}
## Shows the NEXT ROUND button.
var show_next := false:
	set(v):
		show_next = v
		queue_redraw()

# Layout (screen coordinates), set by place().
var _stick_home := Vector2(150, 560)   # where the MOVE hint is drawn
var _stick_area := Rect2(0, 0, 640, 720)  # touching here starts the joystick
var _cluster := Vector2(1110, 560)
var _next_center := Vector2(640, 660)
var _scale := 1.0

var _stick_finger := -1
var _stick_base := Vector2.ZERO
var _fingers := {}  # finger index -> button name it holds
var _use_mouse := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_use_mouse = not DisplayServer.is_touchscreen_available()


## stick_home: centre of the MOVE hint; stick_area: where a thumb starts the joystick;
## cluster: centre of the four buttons; next_center: NEXT ROUND button; ui_scale: size.
func place(stick_home: Vector2, stick_area: Rect2, cluster: Vector2, next_center: Vector2, ui_scale: float) -> void:
	_stick_home = stick_home
	_stick_area = stick_area
	_cluster = cluster
	_next_center = next_center
	_scale = ui_scale
	queue_redraw()


func is_held(button: StringName) -> bool:
	return _fingers.values().has(button)


func release_all() -> void:
	_fingers.clear()
	_stick_finger = -1
	stick = Vector2.ZERO
	queue_redraw()


func _stick_radius() -> float:
	return 80.0 * _scale


func _button_radius() -> float:
	return 48.0 * _scale


func _button_pos(b: StringName) -> Vector2:
	return _cluster + BUTTONS[b]["dir"] * 88.0 * _scale


func _next_rect() -> Rect2:
	var s := Vector2(230, 66) * _scale
	return Rect2(_next_center - s / 2.0, s)


func _input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	if event is InputEventScreenTouch:
		_touch(event.index, event.position, event.pressed)
	elif event is InputEventScreenDrag:
		_drag(event.index, event.position)
	elif _use_mouse and event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_touch(100, event.position, event.pressed)
	elif _use_mouse and event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT):
		_drag(100, event.position)


func _touch(finger: int, pos: Vector2, down: bool) -> void:
	if down:
		if show_next and _next_rect().grow(12.0).has_point(pos):
			_press(finger, &"start")
			return
		for b: StringName in BUTTONS:
			if pos.distance_to(_button_pos(b)) <= _button_radius() * 1.3:
				_press(finger, b)
				return
		if _stick_area.has_point(pos) and _stick_finger < 0:
			_stick_finger = finger
			_stick_base = pos
			stick = Vector2.ZERO
			get_viewport().set_input_as_handled()
			queue_redraw()
	else:
		if finger == _stick_finger:
			_stick_finger = -1
			stick = Vector2.ZERO
			queue_redraw()
		elif _fingers.has(finger):
			_fingers.erase(finger)
			queue_redraw()


func _drag(finger: int, pos: Vector2) -> void:
	if finger != _stick_finger:
		return
	var r := _stick_radius()
	var offset := pos - _stick_base
	if offset.length() > r:
		# Drag the base along so reversing direction is instant.
		_stick_base = pos - offset.normalized() * r
		offset = pos - _stick_base
	stick = offset / r
	if stick.length() < 0.15:
		stick = Vector2.ZERO
	queue_redraw()


func _press(finger: int, b: StringName) -> void:
	_fingers[finger] = b
	press_counts[b] = int(press_counts.get(b, 0)) + 1
	button_down.emit(b)
	get_viewport().set_input_as_handled()
	queue_redraw()


func _draw() -> void:
	var font := ThemeDB.fallback_font
	var r := _stick_radius()
	# Joystick (only while a thumb is on it) or a hint where it goes.
	if _stick_finger >= 0:
		draw_circle(_stick_base, r, Color(1, 1, 1, 0.08))
		draw_arc(_stick_base, r, 0, TAU, 40, Color(1, 1, 1, 0.3), 3.0)
		draw_circle(_stick_base + stick * r, 36.0 * _scale, Color(1, 1, 1, 0.4))
	else:
		draw_circle(_stick_home, r, Color(1, 1, 1, 0.04))
		draw_arc(_stick_home, r, 0, TAU, 40, Color(1, 1, 1, 0.18), 3.0)
		draw_circle(_stick_home, 36.0 * _scale, Color(1, 1, 1, 0.12))
		draw_string(font, _stick_home + Vector2(-60, r + 28) * Vector2(1, 1), "MOVE", HORIZONTAL_ALIGNMENT_CENTER, 120,
				int(18 * _scale), Color(1, 1, 1, 0.35))

	var br := _button_radius()
	for b: StringName in BUTTONS:
		var info: Dictionary = BUTTONS[b]
		var pos := _button_pos(b)
		var col: Color = info["color"]
		var held := is_held(b)
		draw_circle(pos, br, Color(col, 0.6 if held else 0.25))
		draw_arc(pos, br, 0, TAU, 40, Color(col, 0.95), 3.0)
		draw_string(font, pos + Vector2(-br, 6 * _scale), info["label"], HORIZONTAL_ALIGNMENT_CENTER, br * 2,
				int(17 * _scale), Color(1, 1, 1, 0.95))

	if show_next:
		var rect := _next_rect()
		draw_rect(rect, Color("#ffb703", 0.9 if is_held(&"start") else 0.7))
		draw_string(font, rect.position + Vector2(0, rect.size.y * 0.63), "NEXT ROUND", HORIZONTAL_ALIGNMENT_CENTER,
				rect.size.x, int(24 * _scale), Color("#0b0d12"))
