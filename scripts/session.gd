extends Node
## Autoload "Session": what the player picked in the menu, handed to the game scene. Also reads
## ?join=CODE from the page address (web builds) and switches the UI between a landscape and a
## portrait design size so the game fits any screen. Reusable as is; change PAGES_URL.

## LOCAL: one screen, phones as controllers / keyboard. ONLINE_HOST: this device runs the match
## and a friend joins with the code. ONLINE_GUEST: this device joined a friend's match.
enum Mode { LOCAL, ONLINE_HOST, ONLINE_GUEST }

## Where the web build is hosted: invite links are PAGES_URL?join=CODE, which open the game and
## join straight away. Change this for your own game.
const PAGES_URL := "https://jalaad.github.io/GameJam-PvP-Online/"

var mode := Mode.LOCAL
## Room code of the online match (guest: the one typed in / from the link).
var join_code := ""
## Code from a ?join=CODE link, used once by the menu.
var link_code := ""
## Shown on the menu once (e.g. why joining failed).
var notice := ""


func _ready() -> void:
	if OS.has_feature("web"):
		var code: Variant = JavaScriptBridge.eval("new URLSearchParams(window.location.search).get('join') || ''")
		link_code = clean_code(str(code))
	get_tree().root.size_changed.connect(_fit_orientation)
	_fit_orientation()


func is_online() -> bool:
	return mode != Mode.LOCAL


## True when the screen is taller than wide (phone held upright).
func is_portrait() -> bool:
	var s := get_tree().root.size
	return s.y > s.x


## The UI is designed with a 720-unit short side in both orientations (1280x720 sideways,
## 720x1280 upright); stretch mode "expand" adds room along the long side to fit any screen.
func _fit_orientation() -> void:
	var root := get_tree().root
	var want := Vector2i(720, 1280) if is_portrait() else Vector2i(1280, 720)
	if root.content_scale_size != want:
		root.content_scale_size = want


static func clean_code(text: String) -> String:
	var out := ""
	for ch in text.to_upper():
		if PhoneControllerServer.CODE_CHARS.contains(ch):
			out += ch
	return out.left(4)


static func invite_url(code: String) -> String:
	return "%s?join=%s" % [PAGES_URL, code]
