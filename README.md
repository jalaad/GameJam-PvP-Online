# PvP Phone Arena (GameJam PvP Online)

A 2-player top-down arena duel for **Godot 4.7**, made to be played on phones. No app install.

**Play in the browser:** https://jalaad.github.io/GameJam-PvP-Online/

The menu offers three ways to play:

| Mode | Screens | How |
|---|---|---|
| **Create / Join online match** | Each player's **own phone** shows the game, with on-screen controls | One player creates a match and gets a 4-character code, a QR code and an invite link; the other taps *Join online match* and types the code, or opens the link |
| **Play on this screen**, phones as controllers | One shared screen (TV, laptop); phones become **controllers** | Players scan the QR code; each phone turns into a joystick + buttons |
| **Play on this screen**, keyboard | One screen, one keyboard | P1 = WASD + K L J I, P2 = Arrows + Numpad 5 6 4 8 |

## Online match (phone vs phone)

1. Open the game on your phone and tap **Create online match**. You get a code like `K7QD`, a QR code and a
   **Share invite link** button.
2. Your friend opens the invite link (`https://jalaad.github.io/GameJam-PvP-Online/?join=K7QD`), scans the QR
   code, or opens the game and taps **Join online match** and types the code.
3. The fight starts as soon as they join. You're Player 1 (blue), your friend is Player 2 (pink).

Both phones can be on any network (Wi-Fi or mobile data), and a computer works too (mouse or keyboard).

**Holding the phone:** either way. Sideways puts the arena in the middle with a control panel on each
side; upright puts the arena on top with the controls below it, like a handheld console. Everything
scales to the screen and re-arranges if you rotate mid-match.

| On-screen control | Action |
|---|---|
| Thumb anywhere on the left half | Joystick: move (360°) |
| ATK | Melee: 12 damage + knockback |
| SHOOT | Projectile: 7 damage, stopped by pillars |
| BLOCK (hold) | Hits from the front do 20% damage; you move slowly |
| DASH | Quick burst; you can't be hurt mid-dash |
| NEXT ROUND | Appears after a knockout; starts the next round |
| Menu (top) | Leave the match (Esc on a keyboard) |

The status line at the top shows the match code, the ping, and how the phones are connected:
*direct link* (WebRTC, fastest) or *via relay* (when a network blocks direct links; still playable, a bit
more delay).

If your friend's connection drops, their fighter waits 30 seconds for them (reloading the page is fine);
after that you're back in the lobby with the same code.

### How it works

- The phone that creates the match **hosts** it: it runs the fight. The friend's phone joins the host's room
  on the [relay](relay/README.md), exactly like a phone controller would, and gets the game state 30 times a
  second.
- In browsers the two phones then open a **direct WebRTC data channel** (negotiated through the relay) for
  input and game state. If it can't open, everything keeps going through the relay. Desktop builds always
  use the relay.
- The guest moves its own fighter immediately (prediction), corrects it from the host's state, and shows the
  host's fighter and bullets 100 ms in the past so they move smoothly (interpolation).
- Inputs carry a sequence number and per-button press counters, so late packets are ignored and a quick tap
  is never lost.

## Phones as controllers (Play on this screen)

1. Pick **Play on this screen**. In a desktop build, allow the Windows Firewall prompt for **Private
   networks**. In the browser build the QR code appears once the relay connects.
2. Each player scans the QR code with a phone and taps **Join**. The first phone becomes Player 1 (blue), the
   second Player 2 (pink); each phone recolours to match.
3. The match starts automatically once both phones join. Playing with the keyboard? Press **Enter** to start
   now. **Tab** brings the QR code back up, **Esc** goes back to the menu.

How phones reach the game (chosen automatically; see `DEFAULT_MODE` / `DEFAULT_RELAY_URL` at the top of
`phone_controller/phone_controller_server.gd`):

| Build | How phones reach the game | Needs |
|---|---|---|
| Desktop (Windows/Mac/Linux) | The game hosts the phone page itself | Phones on the **same Wi-Fi**; no internet |
| Browser (GitHub Pages, itch.io) | Through the [relay](relay/README.md) on Cloudflare | Internet; phones on **any** network |

The phone controller has the same buttons as the on-screen controls (ATTACK / SHOOT / BLOCK / DASH /
NEXT ROUND). The keyboard works too, for either player at any time, even alongside a phone:
P1 = WASD + K attack, L shoot, J block, I dash. P2 = Arrows + Numpad 5 attack, 6 shoot, 4 block, 8 dash.

Phones vibrate when you're hit, win or get knocked out (Android; iPhones can't vibrate from a browser).

## Running and publishing

- **From the Godot editor (4.7):** open this folder and press Play. All three modes work; online matches go
  through the relay.
- **GitHub Pages:** every push to `main` builds the web version and publishes it
  (`.github/workflows/pages.yml`; the repo's Pages source is set to *GitHub Actions*). Invite links point
  there (`PAGES_URL` in `scripts/session.gd`).
- **itch.io / downloads:** export with the *Web* and *Windows Desktop* presets (`export_presets.cfg`), zip
  `build/web` (without `.import` files) and the `.exe`, and upload. On itch.io the game runs inside a frame,
  so invite links always open the GitHub Pages version; the code works from either.
- **Relay:** see [relay/README.md](relay/README.md) to deploy or update it.

## Using this in another game

The multiplayer parts are game-agnostic and can be dropped into another Godot 4 game:
**[docs/REUSE.md](docs/REUSE.md)** explains which file does what, what to copy, and how to wire up
*Play on this screen* (phones as controllers) and *online player vs player* (relay + direct link), with
code examples and the message protocol.

## How it fits together

```
project.godot                 input map, autoloads (PhoneControllers, Session), stretch settings
export_presets.cfg            Web (single-threaded) and Windows Desktop exports
.github/workflows/pages.yml   builds the web version and publishes it to GitHub Pages
phone_controller/
  controller.html             the phone controller page (attack/shoot/block/dash/start)
  phone_controller_server.gd  phones -> game: LAN server (HTTP 8080 + WebSocket 8081) or relay client;
                              WebRTC direct link (host side) for online matches
  qr_code.gd                  QR code generator
relay/                        Cloudflare Worker that pairs games and phones by room code
docs/REUSE.md                 how to reuse the multiplayer parts in another game
scenes/  menu.tscn (start screen) · main.tscn (arena) · fighter.tscn · bullet.tscn
scripts/
  session.gd                  what was picked in the menu (mode, code); portrait/landscape scaling
  menu.gd                     start screen, match-code keypad, ?join= links
  main.gd                     arena, lobby, rounds, HUD, screen layout; online host (snapshots) and
                              guest (prediction, interpolation)
  online_guest.gd             guest networking: relay + WebRTC direct link
  touch_controls.gd           on-screen joystick and buttons (multi-touch)
  fighter.gd                  movement + the 4 actions; keyboard, phone or touch input; network state
  bullet.gd
```

- Balance numbers are constants at the top of `scripts/fighter.gd`.
- Each phone controller button (`data-btn="attack"` etc. in `controller.html`) matches a fighter action
  name, so adding a button is one line there plus handling it in `fighter.gd` (and `touch_controls.gd`).

## Troubleshooting

- **"No match with code …":** the host's match isn't open. Check the code, and keep the host's game open
  (a phone that locks or switches apps pauses the browser tab).
- **"That match is full":** a match has one host and one guest. If your friend reloaded, they get their
  slot back automatically.
- **Status says *via relay*:** that network blocks direct connections (common on some mobile networks).
  The game still works, with a little more delay.
- **Phone controller can't open the page (desktop build):** allow Godot through Windows Firewall (Private),
  and make sure the phone isn't on a guest network. If the QR code shows the wrong IP (VPN/virtual adapters),
  set `host_override` on the `PhoneControllers` autoload.
- **Exporting:** the presets already include `phone_controller/*.html` (needed for the phone page) and
  exclude `relay/`.

Built from [godot-phone-controller](https://github.com/jalaad/godot-phone-controller) (phone page, server,
QR code) and [pvp-arena](https://github.com/jalaad/pvp-arena) (the arena game), via
[pvp-phone-arena](https://github.com/jalaad/pvp-phone-arena).
