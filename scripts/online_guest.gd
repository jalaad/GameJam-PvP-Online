class_name OnlineGuest
extends Node
## The guest side of an online match (the host side is PhoneControllerServer). Game-agnostic:
## it moves messages, the game decides what they mean. See docs/REUSE.md.
##
## Joins the host's relay room as if it were a phone controller (hello with a token, so a page
## reload gets the same player slot back), sends this player's input and receives the host's
## game state. In web builds it also accepts the host's offer of a direct WebRTC link, which then
## carries input and state (lower latency); the relay stays as the fallback and for everything else.
##
##   var guest := OnlineGuest.new()
##   add_child(guest)
##   guest.snapshot.connect(func(st): ...)          # host's "st" messages (game state)
##   guest.failed.connect(func(reason): ...)        # bad code / match full: show reason
##   guest.join("K7QD")
##   # every physics tick:
##   guest.send_fast({"t": "in", "q": seq, "x": stick.x, "y": stick.y, "b": held, "pc": press_counts})
##
## Needs the PhoneControllers autoload only for get_relay_url() and the shared constants.

## The host accepted us; player_id is our slot on the host (PhoneControllers id there).
signal joined(player_id: int)
## Could not join (bad code, match full...). reason is shown to the player.
signal failed(reason: String)
## The link dropped; we're trying again (with the same token, so we keep our slot).
signal reconnecting
## A game-state message from the host ({"t": "st", ...}; the contents are up to the game).
signal snapshot(state: Dictionary)
## Any other message from the host: "msg", "vibrate", "theme", or the game's own types.
signal message(msg: Dictionary)

const _RETRY_SEC := 1.5
const _PING_SEC := 1.0

var code := ""
var player_id := 0
## Round-trip time to the host in ms (-1 until measured).
var rtt_ms := -1

var _ws: WebSocketPeer
var _token := ""
var _name := ""
var _retry_at := -1.0
var _welcomed := false
var _hello_sent := false
var _given_up := false
var _last_ping := 0.0
var _rtc: WebRTCPeerConnection
var _channel: WebRTCDataChannel


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_token = "g" + str(randi()) + str(Time.get_ticks_usec())
	if OS.has_feature("web"):
		# Same id after a page reload, so the host gives us our slot back instead of "full".
		var saved: Variant = JavaScriptBridge.eval(
				"(function(t){ try { var k='pvp_guest_token'; var v=localStorage.getItem(k); if (!v) { v=t; localStorage.setItem(k, v); } return v; } catch (e) { return t; } })('%s')" % _token)
		if saved is String and saved != "":
			_token = saved


func join(room_code: String, player_name := "") -> void:
	code = room_code
	_name = player_name
	_given_up = false
	_connect()


func leave() -> void:
	_given_up = true
	_close_rtc()
	if _ws:
		_ws.close(1000, "bye")
		_ws = null


func has_direct_link() -> bool:
	return _channel != null and _channel.get_ready_state() == WebRTCDataChannel.STATE_OPEN


func is_connected_to_host() -> bool:
	return _welcomed and _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN


## Reliable path (relay).
func send(msg: Dictionary) -> void:
	if _ws and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_ws.send_text(JSON.stringify(msg))


## Direct link if open (unreliable, fastest), relay otherwise.
func send_fast(msg: Dictionary) -> void:
	if has_direct_link():
		_channel.put_packet(JSON.stringify(msg).to_utf8_buffer())
	else:
		send(msg)


func _connect() -> void:
	_close_rtc()
	_welcomed = false
	_hello_sent = false
	_retry_at = -1.0
	_ws = WebSocketPeer.new()
	if _ws.connect_to_url("%s/ws/phone/%s" % [PhoneControllers.get_relay_url(), code]) != OK:
		_ws = null
		_retry_at = _now() + _RETRY_SEC


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


func _process(_delta: float) -> void:
	var now := _now()
	if _ws == null:
		if not _given_up and _retry_at >= 0.0 and now >= _retry_at:
			_connect()
		return
	_ws.poll()
	match _ws.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if not _hello_sent:
				_hello_sent = true
				send({"t": "hello", "s": code, "name": _name, "token": _token,
						"rtc": PhoneControllerServer.rtc_supported()})
			while _ws.get_available_packet_count() > 0:
				_on_text(_ws.get_packet().get_string_from_utf8())
			if _welcomed and now - _last_ping > _PING_SEC:
				_last_ping = now
				send_fast({"t": "ping", "ts": Time.get_ticks_msec()})
		WebSocketPeer.STATE_CLOSED:
			var close_code := _ws.get_close_code()
			var reason := _ws.get_close_reason()
			_ws = null
			_close_rtc()
			_welcomed = false
			if _given_up:
				return
			if close_code == 4004 and player_id == 0:
				_give_up("No match with code %s. Check the code, or ask your friend to create one." % code)
			elif close_code == 4001 and reason in ["full", "old_session", "kicked"]:
				_give_up("That match is full." if reason != "old_session" else "That match has ended.")
			else:
				reconnecting.emit()
				_retry_at = now + _RETRY_SEC
	_poll_rtc()


func _give_up(reason: String) -> void:
	_given_up = true
	failed.emit(reason)


func _on_text(text: String) -> void:
	var msg: Variant = JSON.parse_string(text)
	if typeof(msg) != TYPE_DICTIONARY:
		return
	match str(msg.get("t", "")):
		"welcome":
			_welcomed = true
			player_id = int(msg.get("id", 0))
			joined.emit(player_id)
		"reject":
			_give_up("That match is full." if msg.get("reason") == "full" else "Couldn't join (%s)." % msg.get("reason"))
		"st":
			snapshot.emit(msg)
		"pong":
			rtt_ms = Time.get_ticks_msec() - int(msg.get("ts", 0))
		"rtc_sdp":
			_on_rtc_sdp(str(msg.get("type", "")), str(msg.get("sdp", "")))
		"rtc_ice":
			if _rtc:
				_rtc.add_ice_candidate(str(msg.get("media", "")), int(msg.get("index", 0)), str(msg.get("name", "")))
		_:
			message.emit(msg)


# --- Direct link ---------------------------------------------------------------

func _on_rtc_sdp(type: String, sdp: String) -> void:
	if type == "offer":
		_close_rtc()
		var peer := WebRTCPeerConnection.new()
		if peer.initialize({"iceServers": PhoneControllerServer.ICE_SERVERS}) != OK:
			return
		_rtc = peer
		_channel = PhoneControllerServer.make_fast_channel(peer)
		peer.session_description_created.connect(func(t: String, s: String) -> void:
			if _rtc != peer:
				return
			peer.set_local_description(t, s)
			send({"t": "rtc_sdp", "type": t, "sdp": s}))
		peer.ice_candidate_created.connect(func(media: String, index: int, cand: String) -> void:
			if _rtc == peer:
				send({"t": "rtc_ice", "media": media, "index": index, "name": cand}))
	if _rtc:
		_rtc.set_remote_description(type, sdp)  # an offer makes it create our answer


func _close_rtc() -> void:
	if _rtc:
		_rtc.close()
	_rtc = null
	_channel = null


func _poll_rtc() -> void:
	if _rtc == null:
		return
	_rtc.poll()
	while _channel != null and _channel.get_available_packet_count() > 0:
		_on_text(_channel.get_packet().get_string_from_utf8())
