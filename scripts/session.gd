extends Node
## Autoload "Session": what the player picked in the menu, read by the arena.

enum Mode { LOCAL, ONLINE_HOST, ONLINE_GUEST }

## Web build hosted where a ?join=CODE link opens the game and joins straight away.
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


func is_online() -> bool:
	return mode != Mode.LOCAL


static func clean_code(text: String) -> String:
	var out := ""
	for ch in text.to_upper():
		if PhoneControllerServer._CODE_CHARS.contains(ch):
			out += ch
	return out.left(4)


static func invite_url(code: String) -> String:
	return "%s?join=%s" % [PAGES_URL, code]
