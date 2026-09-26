class_name TouchControls
extends Control
## On-screen controls for playing on the phone itself: a floating joystick on the left half of
## the screen and four action buttons on the right. Multi-touch, so you can move and attack at
## once. Without a touchscreen the mouse works too (handy on desktop).

signal button_down(button: StringName)

const STICK_RADIUS := 80.0
const BUTTON_RADIUS := 50.0
## Button layout around the cluster centre (bottom right).
const BUTTONS := {
	&"attack": {"offset": Vector2(92, 0), "label": "ATK", "color": Color("#ff5d73")},
	&"shoot": {"offset": Vector2(0, -92), "label": "SHOOT", "color": Color("#ffb703")},
	&"block": {"offset": Vector2(-92, 0), "label": "BLOCK", "color": Color("#8ecae6")},
	&"dash": {"offset": Vector2(0, 92), "label": "DASH", "color": Color("#b8f35a")},
}

## Joystick, each axis -1..1, y+ is down.
var stick := Vector2.ZERO
## Presses so far per button (never reset), for clients that send counts.
var press_counts := {}
## Shows the NEXT ROUND button (top centre).
var show_next := false:
	set(v):
		show_next = v
		queue_redraw()

var _stick_finger := -1
var _stick_base := Vector2.ZERO
var _stick_knob := Vector2.ZERO
var _fingers := {}  # finger index -> button name it holds
var _use_mouse := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_use_mouse = not DisplayServer.is_touchscreen_available()
	resized.connect(queue_redraw)


func is_held(button: StringName) -> bool:
	return _fingers.values().has(button)


func held_buttons() -> Array:
	var out := []
	for b: StringName in _fingers.values():
		if not out.has(b):
			out.append(b)
	return out


func release_all() -> void:
	_fingers.clear()
	_stick_finger = -1
	stick = Vector2.ZERO
	queue_redraw()


func _cluster_center() -> Vector2:
	return Vector2(size.x - 170.0, size.y - 160.0)


func _next_rect() -> Rect2:
	return Rect2(size.x / 2.0 - 110.0, size.y - 86.0, 220.0, 64.0)


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
		var center := _cluster_center()
		for b: StringName in BUTTONS:
			if pos.distance_to(center + BUTTONS[b]["offset"]) <= BUTTON_RADIUS * 1.3:
				_press(finger, b)
				return
		if pos.x < size.x * 0.5 and _stick_finger < 0:
			_stick_finger = finger
			_stick_base = pos
			_stick_knob = pos
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
	var offset := pos - _stick_base
	if offset.length() > STICK_RADIUS:
		# Drag the base along so reversing direction is instant.
		_stick_base = pos - offset.normalized() * STICK_RADIUS
		offset = pos - _stick_base
	_stick_knob = pos
	stick = offset / STICK_RADIUS
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
	# Joystick (only while a finger is on it) or a hint where it goes.
	if _stick_finger >= 0:
		draw_circle(_stick_base, STICK_RADIUS, Color(1, 1, 1, 0.08))
		draw_arc(_stick_base, STICK_RADIUS, 0, TAU, 40, Color(1, 1, 1, 0.25), 3.0)
		draw_circle(_stick_base + stick * STICK_RADIUS, 34.0, Color(1, 1, 1, 0.35))
	else:
		var hint := Vector2(150.0, size.y - 160.0)
		draw_arc(hint, STICK_RADIUS, 0, TAU, 40, Color(1, 1, 1, 0.12), 3.0)
		draw_string(font, hint + Vector2(-60, 6), "MOVE", HORIZONTAL_ALIGNMENT_CENTER, 120, 18, Color(1, 1, 1, 0.3))

	var center := _cluster_center()
	for b: StringName in BUTTONS:
		var info: Dictionary = BUTTONS[b]
		var pos: Vector2 = center + info["offset"]
		var col: Color = info["color"]
		var held := is_held(b)
		draw_circle(pos, BUTTON_RADIUS, Color(col, 0.55 if held else 0.22))
		draw_arc(pos, BUTTON_RADIUS, 0, TAU, 40, Color(col, 0.9), 3.0)
		draw_string(font, pos + Vector2(-50, 6), info["label"], HORIZONTAL_ALIGNMENT_CENTER, 100, 17, Color(1, 1, 1, 0.9))

	if show_next:
		var r := _next_rect()
		draw_rect(r, Color("#ffb703", 0.85 if is_held(&"start") else 0.6))
		draw_string(font, r.position + Vector2(0, 41), "NEXT ROUND", HORIZONTAL_ALIGNMENT_CENTER, r.size.x, 24, Color("#0b0d12"))
