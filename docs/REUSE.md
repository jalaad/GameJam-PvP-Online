# Reusing this in another game

This project has two multiplayer features you can take into another Godot 4 game:

- **A. Play on this screen:** one screen shows the game, and phones scan a QR code to become controllers.
- **B. Online player vs player:** each player uses their own device. The devices connect through a relay,
  and in browsers they then switch to a **direct** WebRTC link.

Both run on the same two building blocks, the **PhoneControllers** autoload and the **relay**. This guide
covers which part does what, what to copy, and how to wire each feature into your game.

---

## 1. The parts

```
┌──────────────── your game (Godot) ────────────────┐          ┌──────── relay (Cloudflare) ────────┐
│                                                   │          │                                    │
│  PhoneControllers  (autoload, game-agnostic)      │◄── wss ──┤  /ws/host/CODE   Room CODE         │
│   · LAN server (desktop) or relay client          │          │  /ws/phone/CODE  forwards messages │
│   · players: stick + buttons, join/leave/rejoin   │          │  /?r=CODE        phone page        │
│   · send()/send_fast(); WebRTC host side          │          └──────────▲───────────────▲─────────┘
│                                                   │                     │ wss           │ wss
│  OnlineGuest  (game-agnostic)  ───────────────────┼─────────────────────┘               │
│   · joins a host's room, WebRTC guest side        │    (the guest's copy of the game)   │
│                                                   │                                     │
│  TouchControls  (game-agnostic)                   │           controller.html ──────────┘
│  Session  (menu choice, ?join=, screen scaling)   │           (phone controller page)
│                                                   │
│  main.gd / fighter.gd  (THIS game: rules, netcode │   direct link (WebRTC data channel, web builds)
│   state, layout)                                  │   host ◄═══════════════════════════════► guest
└───────────────────────────────────────────────────┘
```

| File | What it does | Reuse |
|---|---|---|
| `phone_controller/phone_controller_server.gd` | The game's side of every remote connection. Handles the LAN server or relay client, the player list, input, rejoin by token, `send` / `send_fast`, and the host side of WebRTC | **As is** |
| `phone_controller/controller.html` | The phone controller page: joystick, buttons, reconnect, vibration. The game serves it itself (LAN) or uploads it to its relay room, so edits show up after a restart in both modes | **As is**; edit the buttons and look |
| `phone_controller/qr_code.gd` | QR code generator for the join link | **As is** |
| `relay/` | Cloudflare Worker that pairs a game with its devices by room code, and serves each room the controller page its game uploaded | **As is** (share this one, or deploy your own under a new name) |
| `scripts/online_guest.gd` | The guest side of an online match: joins the host's room, sends input, receives state, and handles the guest side of WebRTC | **As is** |
| `scripts/touch_controls.gd` | On-screen joystick and buttons with multi-touch, placed by the game | **As is**; edit `BUTTONS` |
| `scripts/session.gd` | Stores the menu choice (mode and code), reads `?join=` links, and switches between portrait and landscape design sizes | **As is**; change `PAGES_URL` |
| `scripts/menu.gd` | Start screen and match-code keypad | Copy and restyle |
| `scripts/main.gd` | This game's arena and rounds, plus the **netcode pattern** (host snapshots, guest prediction and interpolation) and the screen layout | **Pattern**: copy the online sections and replace the state |
| `scripts/fighter.gd` | This game's player: movement and actions, plus `step` / `get_state` / `apply_state` for the netcode | **Pattern**: give your player the same three functions |
| `.github/workflows/pages.yml` | Publishes the web build to GitHub Pages on every push | **As is** |

---

## 2. Setting up another project

1. **Copy these into your project:**
   - `phone_controller/` (all three files)
   - `scripts/online_guest.gd`, `scripts/touch_controls.gd` and `scripts/session.gd`
   - optionally `scripts/menu.gd` + `scenes/menu.tscn`, and `.github/workflows/pages.yml`
2. **Register the autoloads** (Project → Project Settings → Globals):
   - `PhoneControllers` → `res://phone_controller/phone_controller_server.gd`
   - `Session` → `res://scripts/session.gd`
3. **Set the display options** (only needed if you want the portrait/landscape scaling from `Session`):
   - `display/window/stretch/mode = "canvas_items"`
   - `display/window/stretch/aspect = "expand"`
   - base size 1280×720
4. **Set up exports.** Under Export → Resources → *Filters to export non-resource files*, add
   `phone_controller/*.html`; under *Filters to exclude*, add `relay/*`. For the web export, turn thread
   support **off**, so it runs on GitHub Pages and itch.io without special headers.
5. **Pick a relay.** Either:
   - keep `DEFAULT_RELAY_URL` in `phone_controller_server.gd` pointing at the existing relay. Your game
     uploads its own `controller.html` to its room, so sharing a relay doesn't mix up controller pages.
     The daily request allowance is shared too, though (section 7), or
   - deploy your own copy of `relay/` (see [relay/README.md](../relay/README.md)) and change the URL.
     **Change `"name"` in `relay/wrangler.jsonc` first:** deploying with an existing name to the same
     Cloudflare account replaces that relay.
   - Either way, use a `phone_controller_server.gd` that uploads the page (it has `upload_page_to_relay`).
     An older copy doesn't, and its phones get the relay's built-in page instead of yours.

   Also change `PAGES_URL` in `session.gd` to where your web build will live.
6. **Choose when it starts.** `PhoneControllers.auto_start` is off, so nothing opens until your game calls
   `PhoneControllers.start(...)` for the mode the player picked.

---

## 3. Feature A: Play on this screen (phones as controllers)

```gdscript
func _ready() -> void:
    PhoneControllers.max_players = 2
    PhoneControllers.start()                 # "auto": LAN on desktop, relay in web builds
    PhoneControllers.status_changed.connect(func(_ok, _msg): _show_qr())
    PhoneControllers.player_joined.connect(_on_joined)
    PhoneControllers.player_left.connect(_on_left)
    PhoneControllers.button_pressed.connect(_on_button)

func _show_qr() -> void:
    if PhoneControllers.can_join:            # in relay mode, once the room is open
        $QR.texture = PhoneControllers.make_qr_texture(10)   # TextureRect, filter Nearest
        $Url.text = PhoneControllers.get_join_url()

func _on_joined(id: int) -> void:
    var p := PhoneControllers.get_player(id)
    PhoneControllers.set_player_theme(id, Color.RED, "P1 · " + p.name)   # recolour the phone
    # give player `id` a character...

func _physics_process(_delta: float) -> void:
    for p in PhoneControllers.get_players():
        var move: Vector2 = p.stick          # -1..1, y+ down
        var blocking: bool = p.is_pressed(&"block")

func _on_button(id: int, button: StringName) -> void:   # one call per tap, never missed
    if button == &"attack": ...
```

- **Button names** come from `data-btn="..."` in `controller.html`. Rename or add buttons there and your game
  receives the new names. The small top button is `start`.
- **Changing the page:** edit `phone_controller/controller.html`, then restart the game (or re-export). The
  page is read at every `start()`:
  - in LAN mode the game serves it itself
  - in relay mode it uploads it to its room, and the relay serves it at `/?r=CODE`

  No relay redeploy is needed. If phones still show an old page, check the join link: `…workers.dev/?r=`
  means relay mode, `http://192.168.x.x:8080/?s=` means LAN mode. Then make sure the game you're running
  is the project you edited.
- **Feedback to the phone:** `vibrate(id, ms_or_pattern)`, `send_text(id, "FIGHT!")`,
  `set_player_theme(id, color, label)`.
- **Dropped phones:** a phone that drops (screen lock, Wi-Fi blip) fires `player_disconnected`. It keeps
  its slot for `reconnect_grace_sec`, and `player_reconnected` fires when it comes back.
- **In this game:** see `_setup_local` and the "Phones (local mode)" section of `scripts/main.gd`.

---

## 4. Feature B: Online player vs player (relay + direct link)

### The model

- One device is the **host**. It runs the real game, is authoritative, and decides every hit.
- The other device is the **guest**. It sends its input and draws what the host tells it.
- Connection:
  - The host calls `PhoneControllers.start("relay")`, which opens a relay room. `session_code` is the code
    the friend types.
  - The guest runs `OnlineGuest.join(code)` and appears on the host as a normal player: `player_joined`,
    plus a `stick` and `buttons` like any phone.
- The direct link (web builds only):
  - The guest's hello says `"rtc": true`, so the host offers a WebRTC connection through the relay.
  - When the data channel opens, `send_fast()` on both sides switches to it automatically.
  - `PhoneControllers.has_fast_path(id)` and `OnlineGuest.has_direct_link()` tell you which path is in use.
  - If the link never opens (strict networks), everything keeps working through the relay.
  - There's no TURN server, only STUN (`ICE_SERVERS`), so the relay is the fallback.

### What your player object needs

Give the thing each player controls these three functions. See `scripts/fighter.gd`:

| Function | Used by | What it does |
|---|---|---|
| `step(delta, input, act)` | host (every tick); guest (predicting and replaying its own player) | Advance one physics tick from an input dictionary. `act = false` means "move only": the guest never decides attacks |
| `get_state() -> Array` | host, for snapshots | Everything needed to draw it and to keep simulating it: position, velocity, cooldowns and so on. Use compact ints |
| `apply_state(state)` | guest | Set it back from a snapshot |

### Host side

The host side is `_setup_host`, `_physics_process` and "Online: host" in `main.gd`.

```gdscript
PhoneControllers.max_players = 1
PhoneControllers.start("relay")                  # show PhoneControllers.session_code + invite link
PhoneControllers.player_joined.connect(func(id): guest_id = id)   # the guest's player drives player 2

func _physics_process(_delta):
    # Remember which guest input this tick uses, so the snapshot can confirm it.
    var p := PhoneControllers.get_player(guest_id)
    acked_seq = p.last_input_seq if p else -1

func _process(delta):                            # ~30 times a second
    PhoneControllers.send_fast(guest_id, {"t": "st", "ts": Time.get_ticks_msec(), "q": acked_seq,
            "f": [p1.get_state(), p2.get_state()], ...})
```

The guest's stick and buttons arrive on the host exactly like a phone's, so player 2 reads
`PhoneControllers.get_stick(guest_id)` and `button_pressed`.

### Guest side

The guest side is `_setup_guest` and "Online: guest" in `main.gd`.

```gdscript
guest = OnlineGuest.new(); add_child(guest)
guest.snapshot.connect(_on_snapshot)            # store it; apply in the next physics tick
guest.failed.connect(func(reason): show_error(reason))
guest.join(code)

func _physics_process(delta):                   # every tick
    var inp := sample_input()                   # touch + keyboard
    seq += 1
    pending.append({"q": seq, "inp": inp})
    my_player.step(delta, inp, false)           # PREDICT: move now, don't wait for the host
    guest.send_fast({"t": "in", "q": seq, "x": inp.move.x, "y": inp.move.y,
                     "b": held_buttons, "pc": press_counts})

func apply_snapshot(st):                        # RECONCILE
    drop entries of `pending` with q <= st.q    # the host has already used those inputs
    my_player.apply_state(st.f[mine])           # rewind to the host's truth
    for e in pending: my_player.step(1.0 / 60, e.inp, false)   # replay what it hasn't seen
    # (fighter.smooth_correction eases small differences in visually)

func _process(_delta):                          # INTERPOLATE the other player
    # draw the other player at (now - 100 ms) between the two snapshots around that time
```

### Why the input message looks like that

- `q` (sequence number): the direct link is unreliable and unordered. The host ignores anything older than
  what it already has, and echoes the newest `q` it used, so the guest knows what to replay.
- `pc` (press count per button): a quick tap might fall between two messages, or its message might be
  lost. Counts only go up, so the host fires `button_pressed` once for every increase and never misses a
  tap.
- `b` (held buttons): used for things you hold, like block.

### Invite links and the menu

- `Session.invite_url(code)` builds `PAGES_URL?join=CODE`.
- In a web build, `Session` reads `?join=` at startup and the menu joins straight away.
- `menu.gd` has the code keypad. Codes use `PhoneControllerServer.CODE_CHARS` (no 0/O/1/I).

---

## 5. On-screen controls and screen fitting

- `TouchControls` supplies `stick`, `is_held()`, `button_down` and `press_counts`. Call
  `place(stick_home, stick_area, cluster, next_center, scale)` whenever the screen size changes.
- `Session` switches the design size between 1280×720 (landscape) and 720×1280 (portrait). Text and buttons
  keep their physical size either way.
- `main.gd` `_layout()` fits the 1280×720 game view into part of the screen:
  - it sets the camera zoom and position
  - it scales the HUD `CanvasLayer`s with the same transform
  - it gives the touch controls the leftover space: side panels in landscape, the lower part in portrait

---

## 6. Protocol reference

All messages are JSON objects, and `t` is the type. Through the relay, the host sees each device's
messages wrapped as `{"c": id, "m": {...}}`; `PhoneControllerServer` unwraps them.

| Direction | Message | Meaning |
|---|---|---|
| device → game | `hello {s, name, token, rtc?}` | Join the session `s`. The same `token` gets the same slot back. `rtc: true` asks for a direct link |
| device → game | `in {x, y, b, q?, pc?}` | Stick, held buttons, and (game clients only) sequence number and press counts |
| device → game | `ping {ts}` | The game answers `pong {ts}` over the same path |
| both | `rtc_sdp {type, sdp}`, `rtc_ice {media, index, name}` | WebRTC setup, sent over the normal connection |
| game → device | `welcome {id, name, color}` / `reject {reason}` | Joined / turned away (`full`, `old_session`, `kicked`) |
| game → device | `theme`, `msg`, `vibrate` | Controller look, a banner message, rumble |
| game → device | anything via `send` / `send_fast` | This game sends `st` (snapshot: `ts`, `q`, `ph` phase, `w` winner, `sc` scores, `f` fighter states, `b` bullets) |

Between the game and the relay only (not forwarded): the relay sends `_room {room}` when the room is open;
the game then sends `_page {html}` (its controller page, served at `/?r=CODE`) and wraps device traffic as
`{"c": id, "m": {...}}` / `{"c": id, "close": reason}`; `"ping"` / `"pong"` keep the socket alive.

Relay close codes that devices see: 4004 `no_game` (no game has that code), 4005 `host_left`, 4001 with a
reason, 4009 `room_taken` (host side, when a new code is picked automatically).

---

## 7. Limits and gotchas

- **WebRTC only in browser builds.** Desktop Godot would need the webrtc-native extension, so desktop
  builds use the relay for online play. It still works, with a bit more delay.
- **Keep the host in the foreground.** A browser tab pauses when the phone locks or switches apps, which
  pauses the match for both players.
- **Relay limits:** at most 8 devices per room. Forwarded messages over 4096 characters are dropped, and an
  uploaded controller page can be up to 512 KB. There's no authentication: anyone with the code can join
  (the host's `max_players` still applies).
- **The free plan's daily request limit:** 100,000 requests a day, shared by every game using the same
  relay; it resets at 00:00 UTC.
  - Every page load and every (re)connect counts; messages on an open connection don't.
  - Once it's used up, the relay answers everything with **429 / Cloudflare error 1027**: phones can't join
    and matches can't connect.
  - All clients here back off and eventually give up when the other side is gone (table in
    [relay/README.md](../relay/README.md)). Keep that if you change the reconnect code.
  - Don't call `PhoneControllers.start()` repeatedly (e.g. every frame): each call opens a new room.
  - Close controller pages and game tabs you aren't using.
- **Costs:** the free Cloudflare plan covers casual use; the Workers Paid plan lifts the daily limit. See
  relay/README.md.
- **Balance and fairness:** the host has zero latency and the guest has one round trip. Prediction hides
  most of that for movement; hits are always decided by the host.

## 8. Testing tips

- Two copies of the game, one host and one guest, can play through the relay on one computer. Run two
  headless Godot instances with a small `--script` that sets `Session.mode` and presses input actions.
  This project did exactly that; the scripts live in the git-ignored `.dev/` folder.
- For the direct link, export the web build, serve `build/web` locally, and open it in two browser windows,
  one creating a match and one opening `?join=CODE`. Real phones are the final check.
