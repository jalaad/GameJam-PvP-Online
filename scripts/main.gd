extends Node2D
## Arena, lobby, round flow and HUD. Three ways to play (chosen in the menu, see Session):
##
##   LOCAL        This screen shows the arena. Players scan the QR code to use their phones as
##                controllers (first phone = Player 1), or share the keyboard.
##   ONLINE_HOST  Phone vs phone: this device runs the match and plays Player 1 with on-screen
##                controls. The friend joins with the match code through the relay, like a
##                phone controller would, and gets the game state ~30 times a second.
##   ONLINE_GUEST The friend's side: plays Player 2 with on-screen controls. Its own fighter
##                moves instantly (predicted, then corrected by the host's state); the host's
##                fighter and bullets are shown slightly in the past, interpolated, so they
##                move smoothly.
##
## This file is the game-specific glue. Sections, and what to copy into another game
## (docs/REUSE.md walks through it):
##   _setup_local / _setup_host / _setup_guest   how each mode wires PhoneControllers, the
##                                              touch controls and OnlineGuest to the players
##   "Phones (local mode)"     assigning phones to player slots: copy and adapt
##   "Online: host"            _send_snapshot + the _acked_seq line in _physics_process: the
##                             host half of the netcode; replace the state it packs
##   "Online: guest"           _guest_tick (sample + send input, predict), _on_snapshot /
##                             _apply_snapshot (rewind + replay), _render_remote (interpolate):
##                             the guest half; the pattern is reusable, the state is not
##   _layout                   fitting the view + control panels to any screen/orientation
##   "Arena", "HUD & lobby"    this game only

const ARENA := Rect2(40, 90, 1200, 590)
const WALL_THICKNESS := 40.0
const PILLARS: Array[Rect2] = [
	Rect2(610, 190, 60, 110),
	Rect2(610, 470, 60, 110),
	Rect2(330, 355, 80, 60),
	Rect2(870, 355, 80, 60),
]
const SPAWNS := [Vector2(200, 385), Vector2(1080, 385)]
const COLOR_NAMES := ["blue", "pink"]
## Design size of the arena view; wider/taller screens get extra margin around it.
const VIEW_SIZE := Vector2(1280, 720)
const MENU_SCENE := "res://scenes/menu.tscn"
const SNAPSHOT_SEC := 1.0 / 30.0
## How far in the past the guest shows the host's fighter, so there's always a newer state
## to move towards.
const INTERP_MS := 100.0

enum Phase { LOBBY, PLAYING, ROUND_OVER }

@onready var fighters: Array[Fighter] = [$Player1, $Player2]

var scores := [0, 0]
var in_lobby := true
var round_over := false

var _bars: Array[ProgressBar] = []
var _name_labels: Array[Label] = []
var _score_labels: Array[Label] = []
var _hud_boxes: Array[Control] = []
var _controls_label: Label
var _message: Label
var _flash_until := 0.0
var _status_label: Label
var _menu_button: Button
var _camera: Camera2D
var _hud_layer: CanvasLayer
var _top_layer: CanvasLayer
var _lobby_row: BoxContainer
var _laid_out_for := Vector2.ZERO
var _lobby: Control
var _slot_labels: Array[Label] = []
var _qr_rect: TextureRect
var _title_label: Label
var _url_label: Label
var _how_label: Label
var _start_label: Label
var _share_button: Button
var _touch: TouchControls
var _winner := 0

# Online host
var _guest_id := 0
var _acked_seq := -1
var _snapshot_timer := 0.0

# Online guest
var _guest: OnlineGuest
var _input_seq := 0
var _pending: Array[Dictionary] = []  # inputs not yet confirmed by the host: {q, inp}
var _press_counts := {}               # StringName -> presses so far (sent to the host)
var _tick_presses := {}               # presses since the last physics tick
var _history: Array[Dictionary] = []  # snapshots for interpolation, oldest first
var _latest: Dictionary = {}          # newest snapshot, not yet applied to our own fighter
var _latest_ts := -1
var _clock_offset := INF              # local ms minus host ms (smallest seen ~ fastest trip)
var _phase := Phase.LOBBY
var _ghost_bullets: Array = []         # [position, color] to draw


func _ready() -> void:
	_camera = Camera2D.new()
	_camera.position = VIEW_SIZE / 2.0
	add_child(_camera)

	_build_walls()
	_build_hud()
	_build_lobby()
	for f in fighters:
		f.health_changed.connect(_on_health_changed)
		f.hurt.connect(_on_fighter_hurt)
		f.died.connect(_on_fighter_died)

	match Session.mode:
		Session.Mode.LOCAL:
			_setup_local()
		Session.Mode.ONLINE_HOST:
			_setup_host()
		Session.Mode.ONLINE_GUEST:
			_setup_guest()
	_layout()
	_show_lobby()


func _setup_local() -> void:
	PhoneControllers.max_players = 2
	PhoneControllers.start()
	PhoneControllers.player_joined.connect(_on_phone_joined)
	PhoneControllers.player_left.connect(_on_phone_left)
	PhoneControllers.player_disconnected.connect(func(_id: int) -> void: _refresh_names())
	PhoneControllers.player_reconnected.connect(func(_id: int) -> void: _refresh_names())
	PhoneControllers.button_pressed.connect(_on_phone_button)
	PhoneControllers.status_changed.connect(func(_ok: bool, _msg: String) -> void: _update_join_info())
	_update_join_info()


func _setup_host() -> void:
	_make_touch_controls()
	fighters[0].touch = _touch
	_touch.button_down.connect(func(b: StringName) -> void:
		if b == &"start":
			_on_start_pressed()
		else:
			fighters[0].phone_button_pressed(b))
	fighters[1].keyboard_enabled = false  # only the friend moves Player 2
	_controls_label.text = "You're Player 1 (blue). Keyboard: WASD + K L J I"

	PhoneControllers.max_players = 1
	PhoneControllers.start("relay")  # the relay is how the friend's device reaches us
	PhoneControllers.player_joined.connect(_on_guest_joined)
	PhoneControllers.player_left.connect(_on_guest_left)
	PhoneControllers.player_disconnected.connect(func(_id: int) -> void: _refresh_names())
	PhoneControllers.player_reconnected.connect(func(_id: int) -> void: _refresh_names())
	PhoneControllers.button_pressed.connect(_on_phone_button)
	PhoneControllers.status_changed.connect(func(_ok: bool, _msg: String) -> void: _update_join_info())
	_update_join_info()


func _setup_guest() -> void:
	_make_touch_controls()
	_touch.button_down.connect(_guest_press)
	fighters[0].sim = Fighter.Sim.REPLICA
	fighters[1].sim = Fighter.Sim.PREDICTED
	for f in fighters:
		f.keyboard_enabled = false
	_controls_label.text = "You're Player 2 (pink). Keyboard: WASD / arrows + K L J I"

	_guest = OnlineGuest.new()
	add_child(_guest)
	_guest.joined.connect(func(_id: int) -> void:
		_how_label.text = "Connected! Starting…"
		_refresh_names())
	_guest.failed.connect(func(reason: String) -> void:
		Session.notice = reason
		_leave())
	_guest.reconnecting.connect(func() -> void: _refresh_names())
	_guest.snapshot.connect(_on_snapshot)
	_guest.message.connect(_on_host_message)
	_guest.join(Session.join_code)
	_update_join_info()


func _make_touch_controls() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 1
	add_child(layer)
	_touch = TouchControls.new()
	layer.add_child(_touch)


func _process(delta: float) -> void:
	var vp := get_viewport().get_visible_rect().size
	if vp != _laid_out_for:  # resized or rotated
		_laid_out_for = vp
		_layout()
	if Input.is_action_just_pressed("restart") and Session.mode != Session.Mode.ONLINE_GUEST:
		_on_start_pressed()
	if _flash_until > 0.0 and Time.get_ticks_msec() / 1000.0 > _flash_until:
		_flash_until = 0.0
		if not round_over:
			_message.visible = false
	match Session.mode:
		Session.Mode.ONLINE_HOST:
			_snapshot_timer += delta
			if _snapshot_timer >= SNAPSHOT_SEC:
				_snapshot_timer = fmod(_snapshot_timer, SNAPSHOT_SEC)
				_send_snapshot()
			_update_status()
		Session.Mode.ONLINE_GUEST:
			_render_remote()
			_update_status()


func _physics_process(delta: float) -> void:
	match Session.mode:
		Session.Mode.ONLINE_HOST:
			# Fighters step right after this with the input received so far: that's what the
			# snapshot confirms to the guest.
			var p := PhoneControllers.get_player(_guest_id)
			_acked_seq = p.last_input_seq if p else -1
		Session.Mode.ONLINE_GUEST:
			_guest_tick(delta)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	# Tab brings the QR code back up so someone can (re)join.
	if event.keycode == KEY_TAB and Session.mode == Session.Mode.LOCAL:
		_show_lobby()
	elif event.keycode == KEY_ESCAPE:
		_leave()


func _leave() -> void:
	if _guest:
		_guest.leave()
	get_tree().change_scene_to_file(MENU_SCENE)
	PhoneControllers.stop()


# --- Flow -------------------------------------------------------------------

func _show_lobby() -> void:
	in_lobby = true
	_lobby.visible = true
	_message.visible = false
	if _touch:
		_touch.visible = false
		_touch.release_all()
	for f in fighters:
		f.set_physics_process(false)
	_refresh_names()


func _hide_lobby() -> void:
	in_lobby = false
	_lobby.visible = false
	if _touch:
		_touch.visible = true
	for f in fighters:
		f.set_physics_process(true)


func _start_match() -> void:
	_hide_lobby()
	for f in fighters:
		if f.phone_id > 0:
			PhoneControllers.send_text(f.phone_id, "FIGHT!", 1200)
	if Session.mode == Session.Mode.ONLINE_HOST:
		_flash("FIGHT!", Color.WHITE)
	_start_round()


func _start_round() -> void:
	round_over = false
	_winner = 0
	_message.visible = false
	if _touch:
		_touch.show_next = false
	fighters[0].reset(SPAWNS[0], Vector2.RIGHT)
	fighters[1].reset(SPAWNS[1], Vector2.LEFT)
	for b in get_tree().get_nodes_in_group("bullets"):
		b.queue_free()


## Enter/Space on the keyboard, or NEXT ROUND on a phone.
func _on_start_pressed() -> void:
	if in_lobby:
		if Session.mode == Session.Mode.LOCAL:
			_start_match()
	elif round_over:
		_start_round()


func _on_health_changed(f: Fighter) -> void:
	_bars[f.player_number - 1].value = f.health


func _on_fighter_hurt(f: Fighter, damage: float) -> void:
	if f.phone_id > 0:
		PhoneControllers.vibrate(f.phone_id, 90 if damage >= 5.0 else 30)
	if f.touch:
		Input.vibrate_handheld(90 if damage >= 5.0 else 30)


func _on_fighter_died(loser: Fighter) -> void:
	if round_over:
		return
	round_over = true
	var winner := fighters[1] if loser == fighters[0] else fighters[0]
	_winner = winner.player_number
	scores[winner.player_number - 1] += 1
	_update_scores()
	_show_round_result()
	if winner.phone_id > 0:
		PhoneControllers.send_text(winner.phone_id, "You win the round!")
		PhoneControllers.vibrate(winner.phone_id, [60, 60, 60])
	if loser.phone_id > 0:
		PhoneControllers.send_text(loser.phone_id, "KO! Tap NEXT ROUND for a rematch")
		PhoneControllers.vibrate(loser.phone_id, [250, 80, 250])
	if loser.touch:
		Input.vibrate_handheld(250)


## Round-over banner, worded for whoever looks at this screen.
func _show_round_result() -> void:
	var color := fighters[_winner - 1].color
	match Session.mode:
		Session.Mode.LOCAL:
			_message.text = "Player %d wins!\nPress NEXT ROUND on a phone, or Enter" % _winner
		_:
			var me := 1 if Session.mode == Session.Mode.ONLINE_HOST else 2
			_message.text = ("You win the round!" if _winner == me else "Your friend wins the round") \
					+ "\nTap NEXT ROUND for a rematch"
	_message.add_theme_color_override("font_color", color)
	_message.visible = true
	_flash_until = 0.0
	if _touch:
		_touch.show_next = true


func _update_scores() -> void:
	for i in 2:
		_score_labels[i].text = "Wins: %d" % scores[i]


## Short centre-screen message.
func _flash(text: String, color: Color, seconds := 1.2) -> void:
	if round_over:
		return
	_message.text = text
	_message.add_theme_color_override("font_color", color)
	_message.visible = true
	_flash_until = Time.get_ticks_msec() / 1000.0 + seconds


# --- Phones (local mode) -------------------------------------------------------

func _fighter_for_phone(id: int) -> Fighter:
	for f in fighters:
		if f.phone_id == id:
			return f
	return null


func _on_phone_joined(id: int) -> void:
	var slot: Fighter = null
	for f in fighters:
		if f.phone_id == 0:
			slot = f
			break
	if slot == null:
		PhoneControllers.kick(id)
		return
	slot.phone_id = id
	var p := PhoneControllers.get_player(id)
	PhoneControllers.set_player_theme(id, slot.color, "P%d · %s" % [slot.player_number, p.name])
	PhoneControllers.send_text(id, "You're Player %d (%s)" % [slot.player_number, COLOR_NAMES[slot.player_number - 1]])
	PhoneControllers.vibrate(id, 60)
	_refresh_names()
	# Everyone's here: start automatically.
	if in_lobby and fighters.all(func(f: Fighter) -> bool: return f.phone_id > 0):
		_start_match()


func _on_phone_left(id: int) -> void:
	var f := _fighter_for_phone(id)
	if f:
		f.phone_id = 0
	_refresh_names()


func _on_phone_button(id: int, button: StringName) -> void:
	if button == &"start":
		_on_start_pressed()
		return
	var f := _fighter_for_phone(id)
	if f:
		f.phone_button_pressed(button)


func _refresh_names() -> void:
	for i in 2:
		var f := fighters[i]
		var who := "keyboard"
		var is_ready := false
		match Session.mode:
			Session.Mode.LOCAL:
				var p := PhoneControllers.get_player(f.phone_id) if f.phone_id > 0 else null
				if p:
					who = p.name + ("" if p.connected else " (reconnecting…)")
					is_ready = true
			Session.Mode.ONLINE_HOST:
				if i == 0:
					who = "You"
					is_ready = true
				else:
					var p := PhoneControllers.get_player(_guest_id) if _guest_id > 0 else null
					who = "Friend" + ("" if p == null or p.connected else " (reconnecting…)") if p else "waiting…"
					is_ready = p != null
			Session.Mode.ONLINE_GUEST:
				var linked := _guest != null and _guest.is_connected_to_host()
				who = ("Friend" if i == 0 else "You") + ("" if linked else " (reconnecting…)")
				is_ready = linked
		_name_labels[i].text = "PLAYER %d · %s" % [f.player_number, who]
		if _slot_labels.size() > i:
			var waiting := "waiting for a phone…" if Session.mode == Session.Mode.LOCAL else "waiting for your friend…"
			_slot_labels[i].text = "P%d  %s" % [f.player_number, who + "  - ready" if is_ready else waiting]
			_slot_labels[i].modulate = Color.WHITE if is_ready else Color(1, 1, 1, 0.55)


# --- Online: host ----------------------------------------------------------------

func _on_guest_joined(id: int) -> void:
	if _guest_id > 0 and _guest_id != id:
		PhoneControllers.kick(id)
		return
	_guest_id = id
	fighters[1].phone_id = id
	PhoneControllers.vibrate(id, 60)
	Input.vibrate_handheld(60)
	_refresh_names()
	if in_lobby:
		_start_match()


func _on_guest_left(id: int) -> void:
	if id != _guest_id:
		return
	_guest_id = 0
	fighters[1].phone_id = 0
	round_over = false
	_update_join_info()
	_show_lobby()


func _send_snapshot() -> void:
	if _guest_id == 0:
		return
	var bullets := []
	for b: Bullet in get_tree().get_nodes_in_group("bullets"):
		if not b.is_queued_for_deletion():
			bullets.append([b.net_id, roundi(b.position.x * 10), roundi(b.position.y * 10), b.shooter.player_number])
	var phase := Phase.LOBBY if in_lobby else (Phase.ROUND_OVER if round_over else Phase.PLAYING)
	PhoneControllers.send_fast(_guest_id, {
		"t": "st",
		"ts": Time.get_ticks_msec(),
		"q": _acked_seq,
		"ph": phase,
		"w": _winner,
		"sc": scores,
		"f": [fighters[0].get_state(), fighters[1].get_state()],
		"b": bullets,
	})


# --- Online: guest ---------------------------------------------------------------

func _guest_press(b: StringName) -> void:
	_press_counts[b] = int(_press_counts.get(b, 0)) + 1
	_tick_presses[b] = true


func _guest_tick(delta: float) -> void:
	if not _latest.is_empty():
		_apply_snapshot(_latest)
		_latest = {}
	if _guest == null or not _guest.is_connected_to_host():
		return

	# This tick's input: keyboard (either player's keys), touch controls.
	var move := Vector2.ZERO
	for p in ["p1_", "p2_"]:
		var v := Input.get_vector(p + "left", p + "right", p + "up", p + "down")
		if v.length() > move.length():
			move = v
		for b in ["attack", "shoot", "dash"]:
			if Input.is_action_just_pressed(p + b):
				_guest_press(StringName(b))
	if Input.is_action_just_pressed("restart"):
		_guest_press(&"start")
	if _touch.stick.length() > move.length():
		move = _touch.stick
	var block := _touch.is_held(&"block") or Input.is_action_pressed("p1_block") or Input.is_action_pressed("p2_block")
	var inp := {
		"move": move, "block": block,
		"dash": _tick_presses.has(&"dash"), "attack": false, "shoot": false,
	}
	_tick_presses.clear()

	_input_seq += 1
	if _phase != Phase.LOBBY:
		_pending.append({"q": _input_seq, "inp": inp})
		if _pending.size() > 120:
			_pending.pop_front()
		fighters[1].step(delta, inp, false)  # move now; the host confirms later
	# Every tick over the direct link; every other tick over the relay.
	if _guest.has_direct_link() or _input_seq % 2 == 0:
		_guest.send_fast({
			"t": "in", "q": _input_seq,
			"x": snappedf(move.x, 0.01), "y": snappedf(move.y, 0.01),
			"b": ["block"] if block else [],
			"pc": _press_counts,
		})


func _on_snapshot(msg: Dictionary) -> void:
	var ts := int(msg.get("ts", 0))
	if ts <= _latest_ts:
		return  # arrived out of order
	_latest_ts = ts
	var now := Time.get_ticks_msec()
	var offset := float(now - ts)
	if offset < _clock_offset:
		_clock_offset = offset
	else:
		_clock_offset += (offset - _clock_offset) * 0.002  # follow slow drift
	_history.append(msg)
	while _history.size() > 40:
		_history.pop_front()
	_latest = msg  # applied at the next physics tick (moving bodies belongs there)


func _apply_snapshot(msg: Dictionary) -> void:
	var phase := int(msg.get("ph", 0)) as Phase
	var sc: Variant = msg.get("sc")
	if sc is Array and sc.size() == 2:
		scores = [int(sc[0]), int(sc[1])]
		_update_scores()
	var states: Variant = msg.get("f")
	if not (states is Array and states.size() == 2):
		return

	if phase != _phase:
		var was := _phase
		_phase = phase
		match phase:
			Phase.LOBBY:
				_show_lobby()
			Phase.PLAYING:
				round_over = false
				_touch.show_next = false
				if _flash_until == 0.0:
					_message.visible = false
			Phase.ROUND_OVER:
				round_over = true
				_winner = int(msg.get("w", 0))
				if _winner > 0:
					_show_round_result()
		if was == Phase.LOBBY and phase != Phase.LOBBY:
			_hide_lobby()
			_pending.clear()  # inputs sent before the fight started don't count

	# Our fighter: take the host's word for where it was after the input it has seen, then
	# replay the inputs it hasn't seen yet.
	var me := fighters[1]
	var acked := int(msg.get("q", -1))
	while not _pending.is_empty() and int(_pending[0]["q"]) <= acked:
		_pending.pop_front()
	var drawn := me.drawn_position()
	me.apply_state(states[1])
	if _phase != Phase.LOBBY:
		var dt := 1.0 / Engine.physics_ticks_per_second
		for entry in _pending:
			me.step(dt, entry["inp"], false)
		me.smooth_correction(drawn)


## Show the host's fighter and bullets INTERP_MS in the past, between two snapshots.
func _render_remote() -> void:
	if _history.is_empty():
		return
	var render_ts := Time.get_ticks_msec() - _clock_offset - INTERP_MS
	var a: Dictionary = _history[0]
	var b: Dictionary = _history[-1]
	for i in range(_history.size() - 1, -1, -1):
		if float(_history[i]["ts"]) <= render_ts:
			a = _history[i]
			b = _history[mini(i + 1, _history.size() - 1)]
			break
	var t := 0.0
	var span := float(b["ts"]) - float(a["ts"])
	if span > 0.0:
		t = clampf((render_ts - float(a["ts"])) / span, 0.0, 1.0)
	elif render_ts < float(a["ts"]):
		b = a  # everything is newer than render time (just started): show the oldest
	fighters[0].apply_state(Fighter.lerp_state(a["f"][0], b["f"][0], t))

	var from := {}
	for bl: Array in a.get("b", []):
		from[int(bl[0])] = bl
	_ghost_bullets.clear()
	for bl: Array in b.get("b", []):
		var pos := Vector2(bl[1], bl[2]) / 10.0
		if from.has(int(bl[0])):
			var old: Array = from[int(bl[0])]
			pos = (Vector2(old[1], old[2]) / 10.0).lerp(pos, t)
		var owner := clampi(int(bl[3]), 1, 2)
		_ghost_bullets.append([pos, fighters[owner - 1].color])
	queue_redraw()


func _on_host_message(msg: Dictionary) -> void:
	match str(msg.get("t", "")):
		"msg":
			_flash(str(msg.get("text", "")), Color.WHITE, float(msg.get("ms", 2500)) / 1000.0)
		"vibrate":
			if msg.has("pattern") and msg["pattern"] is Array and not msg["pattern"].is_empty():
				Input.vibrate_handheld(int(msg["pattern"][0]))
			else:
				Input.vibrate_handheld(int(msg.get("ms", 60)))


func _update_status() -> void:
	var text := ""
	if Session.mode == Session.Mode.ONLINE_HOST:
		text = "Code %s" % PhoneControllers.session_code
		if _guest_id > 0:
			text += " · " + ("direct link" if PhoneControllers.has_fast_path(_guest_id) else "via relay")
	elif _guest:
		text = "Code %s" % Session.join_code
		if _guest.rtt_ms >= 0:
			text += " · %d ms · %s" % [_guest.rtt_ms, "direct link" if _guest.has_direct_link() else "via relay"]
	_status_label.text = text


# --- Arena ------------------------------------------------------------------

func _build_walls() -> void:
	var t := WALL_THICKNESS
	var a := ARENA
	var rects: Array[Rect2] = [
		Rect2(a.position.x - t, a.position.y - t, a.size.x + t * 2, t),  # top
		Rect2(a.position.x - t, a.end.y, a.size.x + t * 2, t),           # bottom
		Rect2(a.position.x - t, a.position.y, t, a.size.y),              # left
		Rect2(a.end.x, a.position.y, t, a.size.y),                       # right
	]
	rects.append_array(PILLARS)
	var body := StaticBody2D.new()
	body.name = "Walls"
	body.collision_layer = 1
	body.collision_mask = 0
	add_child(body)
	for r in rects:
		var shape := CollisionShape2D.new()
		var rect_shape := RectangleShape2D.new()
		rect_shape.size = r.size
		shape.shape = rect_shape
		shape.position = r.get_center()
		body.add_child(shape)


func _draw() -> void:
	draw_rect(ARENA, Color("#12161f"))
	for x in range(int(ARENA.position.x), int(ARENA.end.x), 60):
		draw_line(Vector2(x, ARENA.position.y), Vector2(x, ARENA.end.y), Color("#171c27"), 1.0)
	for y in range(int(ARENA.position.y), int(ARENA.end.y), 60):
		draw_line(Vector2(ARENA.position.x, y), Vector2(ARENA.end.x, y), Color("#171c27"), 1.0)
	draw_rect(ARENA, Color("#2a3142"), false, 4.0)
	for p in PILLARS:
		draw_rect(p, Color("#2a3142"))
		draw_rect(p, Color("#3a4358"), false, 2.0)
	for gb: Array in _ghost_bullets:
		draw_circle(gb[0], 6.0, gb[1])
		draw_circle(gb[0], 3.0, Color.WHITE)


# --- HUD & lobby ------------------------------------------------------------

## Lobby text and QR code. Local: phones scan to become controllers (in relay mode once the
## relay has given us a room). Online host: the invite link and match code for the friend.
func _update_join_info() -> void:
	if _qr_rect == null:
		return
	_share_button.visible = false
	match Session.mode:
		Session.Mode.LOCAL:
			if PhoneControllers.can_join:
				_qr_rect.texture = PhoneControllers.make_qr_texture(10)
				_url_label.text = PhoneControllers.get_join_url()
				_how_label.text = "Scan the code with your phone to grab a fighter.\n" + PhoneControllers.status_message
			else:
				_qr_rect.texture = null
				_url_label.text = ""
				_how_label.text = PhoneControllers.status_message
		Session.Mode.ONLINE_HOST:
			if PhoneControllers.can_join:
				var code := PhoneControllers.session_code
				var link := Session.invite_url(code)
				_qr_rect.texture = QrCode.make_texture(link, 8)
				_title_label.text = "Match code  %s" % code
				_url_label.text = link
				_how_label.text = "Your friend taps Join online match and types the code,\nor scans / opens the link."
				_share_button.visible = true
			else:
				_qr_rect.texture = null
				_title_label.text = "Creating a match…"
				_url_label.text = ""
				_how_label.text = PhoneControllers.status_message
		Session.Mode.ONLINE_GUEST:
			_qr_rect.visible = false
			_title_label.text = "Joining match  %s" % Session.join_code
			_url_label.text = ""
			_how_label.text = "Connecting to your friend…"


func _share_invite() -> void:
	var link := Session.invite_url(PhoneControllers.session_code)
	if OS.has_feature("web"):
		var shared: Variant = JavaScriptBridge.eval(
				"(function(u){ if (navigator.share) { navigator.share({title: 'PvP Phone Arena', text: 'Fight me! Code %s', url: u}).catch(function(){}); return true; } return false; })('%s')"
				% [PhoneControllers.session_code, link])
		if shared:
			return
	DisplayServer.clipboard_set(link)
	_share_button.text = "Link copied!"


## Fits the game to the screen, whatever its size and orientation. The arena and HUD are
## designed as one 1280x720 view, scaled to fit an area of the screen:
##   landscape + touch controls: the middle, with a control panel on each side
##   portrait: the top, with the controls below (like a handheld console)
##   otherwise (desktop, TV): the whole screen
func _layout() -> void:
	var vp := get_viewport().get_visible_rect().size
	var area := Rect2(Vector2.ZERO, vp)
	var portrait := vp.y > vp.x
	var controls := Rect2()
	if portrait and _touch:
		# Arena at the top (below the phone's status bar), controls fill the rest.
		var arena_h := vp.x * VIEW_SIZE.y / VIEW_SIZE.x
		var top := minf(vp.y * 0.05, 80.0)
		area = Rect2(0, top, vp.x, arena_h)
		controls = Rect2(0, area.end.y, vp.x, vp.y - area.end.y)
	elif _touch:
		var side := minf(280.0, vp.x * 0.19)
		area = Rect2(side, 0, vp.x - side * 2.0, vp.y)
	var zoom := minf(area.size.x / VIEW_SIZE.x, area.size.y / VIEW_SIZE.y)
	var view := Rect2(area.get_center() - VIEW_SIZE * zoom / 2.0, VIEW_SIZE * zoom)

	# World: the camera shows the arena scaled into `view`.
	_camera.zoom = Vector2(zoom, zoom)
	_camera.position = VIEW_SIZE / 2.0 - (view.get_center() - vp / 2.0) / zoom
	# HUD: laid out in the same 1280x720 design space, scaled the same way.
	var t := Transform2D(0.0, Vector2(zoom, zoom), 0.0, view.position)
	_hud_layer.transform = t
	_top_layer.transform = t
	_lobby_row.vertical = portrait

	if _touch:
		var hud_bottom := view.position.y + 90.0 * zoom  # below the health bars and Menu button
		var stick_area := Rect2(0, hud_bottom, vp.x / 2.0, vp.y - hud_bottom)
		if portrait:
			var s := clampf(controls.size.y / 420.0, 0.8, 1.3)
			var y := controls.position.y + controls.size.y * 0.58  # a bit low: where thumbs rest
			_touch.place(Vector2(vp.x * 0.24, y), stick_area, Vector2(vp.x * 0.72, y),
					Vector2(vp.x / 2.0, controls.position.y + 70.0 * s), s)
		else:
			var side := area.position.x
			var s := clampf((side - 28.0) / 272.0, 0.6, 1.0)
			var y := vp.y * 0.62
			_touch.place(Vector2(side / 2.0, y), stick_area, Vector2(vp.x - side / 2.0, y),
					Vector2(vp.x / 2.0, view.end.y - 70.0 * zoom), s)


func _build_hud() -> void:
	var hud := CanvasLayer.new()
	_hud_layer = hud
	add_child(hud)

	for i in 2:
		var f := fighters[i]
		var box := VBoxContainer.new()
		box.custom_minimum_size = Vector2(400, 0)
		hud.add_child(box)
		_hud_boxes.append(box)

		var row := HBoxContainer.new()
		box.add_child(row)
		var name_label := Label.new()
		name_label.add_theme_color_override("font_color", f.color)
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.clip_text = true
		row.add_child(name_label)
		_name_labels.append(name_label)
		var score := Label.new()
		score.text = "Wins: 0"
		row.add_child(score)
		_score_labels.append(score)

		var bar := ProgressBar.new()
		bar.max_value = Fighter.MAX_HEALTH
		bar.value = Fighter.MAX_HEALTH
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(400, 18)
		bar.fill_mode = ProgressBar.FILL_BEGIN_TO_END if i == 0 else ProgressBar.FILL_END_TO_BEGIN
		var fill := StyleBoxFlat.new()
		fill.bg_color = f.color
		bar.add_theme_stylebox_override("fill", fill)
		var bg := StyleBoxFlat.new()
		bg.bg_color = Color("#1c212c")
		bar.add_theme_stylebox_override("background", bg)
		box.add_child(bar)
		_bars.append(bar)

	_controls_label = Label.new()
	_controls_label.text = "Phones: stick + ATTACK / SHOOT / BLOCK / DASH     Keyboard  P1: WASD + K L J I   P2: Arrows + Num 5 6 4 8     Tab: show QR"
	_controls_label.add_theme_font_size_override("font_size", 13)
	_controls_label.add_theme_color_override("font_color", Color("#6b7489"))
	hud.add_child(_controls_label)

	_status_label = Label.new()
	_status_label.custom_minimum_size = Vector2(400, 0)
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 14)
	_status_label.add_theme_color_override("font_color", Color("#6b7489"))
	hud.add_child(_status_label)

	_message = Label.new()
	_message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_message.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_message.position = Vector2.ZERO
	_message.size = VIEW_SIZE  # centred on the arena
	_message.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_message.add_theme_font_size_override("font_size", 40)
	_message.add_theme_constant_override("outline_size", 12)
	_message.add_theme_color_override("font_outline_color", Color("#0b0d12"))
	hud.add_child(_message)

	# HUD positions are in the 1280x720 design space; _layout() scales it onto the screen.
	for i in 2:
		_hud_boxes[i].position = Vector2(40 if i == 0 else 840, 16)
	_controls_label.position = Vector2(40, 692)
	_status_label.position = Vector2(440, 14)

	# Above the lobby and touch controls so it always works.
	_top_layer = CanvasLayer.new()
	_top_layer.layer = 3
	add_child(_top_layer)
	_menu_button = Button.new()
	_menu_button.text = "Menu"
	_menu_button.position = Vector2(580, 42)
	_menu_button.custom_minimum_size = Vector2(120, 40)
	_menu_button.focus_mode = Control.FOCUS_NONE
	_menu_button.pressed.connect(_leave)
	_top_layer.add_child(_menu_button)


func _build_lobby() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 2
	add_child(layer)

	_lobby = ColorRect.new()
	(_lobby as ColorRect).color = Color(0.043, 0.051, 0.071, 0.93)
	_lobby.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(_lobby)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_lobby.add_child(center)

	var row := BoxContainer.new()  # side by side; stacked in portrait (see _layout)
	_lobby_row = row
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 40)
	center.add_child(row)

	var qr := TextureRect.new()
	_qr_rect = qr
	qr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	qr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	qr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	qr.custom_minimum_size = Vector2(360, 360)
	qr.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	row.add_child(qr)

	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 14)
	row.add_child(col)

	var title := Label.new()
	_title_label = title
	title.text = "PvP Phone Arena"
	title.add_theme_font_size_override("font_size", 44)
	col.add_child(title)

	var how := Label.new()
	_how_label = how
	how.add_theme_color_override("font_color", Color("#8a93a6"))
	col.add_child(how)

	var url := Label.new()
	_url_label = url
	url.add_theme_color_override("font_color", Color("#6b7489"))
	url.add_theme_font_size_override("font_size", 14)
	col.add_child(url)

	_share_button = Button.new()
	_share_button.text = "Share invite link"
	_share_button.custom_minimum_size = Vector2(0, 52)
	_share_button.add_theme_font_size_override("font_size", 22)
	_share_button.visible = false
	_share_button.pressed.connect(_share_invite)
	col.add_child(_share_button)

	col.add_child(HSeparator.new())
	for f in fighters:
		var slot := Label.new()
		slot.add_theme_font_size_override("font_size", 26)
		slot.add_theme_color_override("font_color", f.color)
		col.add_child(slot)
		_slot_labels.append(slot)
	col.add_child(HSeparator.new())

	_start_label = Label.new()
	_start_label.add_theme_color_override("font_color", Color("#8a93a6"))
	match Session.mode:
		Session.Mode.LOCAL:
			_start_label.text = "Starts automatically when both phones join.\nPlaying with the keyboard? Press Enter to start now."
		Session.Mode.ONLINE_HOST:
			_start_label.text = "The fight starts as soon as your friend joins."
		Session.Mode.ONLINE_GUEST:
			_start_label.text = ""
	col.add_child(_start_label)
