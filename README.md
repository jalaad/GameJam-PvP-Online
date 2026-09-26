# PvP Phone Arena (GameJam PvP Online)

A 2-player top-down arena duel for **Godot 4.7**, played on phones. No app install.
The menu offers three ways to play:

| Mode | Screens | How |
|---|---|---|
| **Create / Join online match** | Each player's **own phone** shows the game, with on-screen controls | One player creates a match and gets a 4-letter code (plus a link/QR); the other taps *Join online match* and types it, or opens the link |
| **Play on this screen** | One shared screen (TV/laptop); phones are **controllers** | Players scan the QR code; phones turn into a joystick + buttons |
| **Play on this screen** + keyboard | One screen, one keyboard | P1 = WASD + K L J I, P2 = Arrows + Numpad 5 6 4 8 |

**Play in the browser:** https://jalaad.github.io/GameJam-PvP-Online/ (an invite link adds `?join=CODE`).

## Online match (phone vs phone)

- The phone that creates the match **hosts** it: it runs the fight and plays Player 1 (blue).
  The friend's phone joins through the relay and plays Player 2 (pink). Both can be on any network
  (Wi-Fi or mobile data).
- In browsers the two phones then open a **direct WebRTC link** for input and game state (the status line
  at the top says *direct link*); if that can't be set up (some mobile networks), everything keeps going
  through the relay (*via relay*). Desktop builds always use the relay.
- The host sends the game state 30 times a second. The guest moves its own fighter immediately and
  corrects it from the host's state, and shows the host's fighter 100 ms in the past so it moves smoothly.
- Hold the phone **either way**: sideways puts the arena in the middle with a control panel on each side;
  upright puts the arena on top with the controls below it, like a handheld console. Everything scales
  to the screen and re-arranges if you rotate mid-match. Put your thumb down anywhere on the left half
  for the joystick; the right side has ATK, SHOOT,
  BLOCK (hold), DASH. **NEXT ROUND** appears after a knockout. **Menu** (top) leaves the match.
- If the friend's connection drops, their fighter waits 30 seconds for them to come back (reloading the
  page is fine); after that the host is back in the lobby with the same code.


## Phones as controllers (Play on this screen)

Two ways phones connect (chosen automatically; see `DEFAULT_MODE` / `DEFAULT_RELAY_URL` at the top of `phone_controller/phone_controller_server.gd`):

| Build | How phones reach the game | Needs |
|---|---|---|
| Desktop (Windows/Mac/Linux) | The game hosts the phone page itself | Phones on the **same Wi-Fi**; no internet |
| Browser (e.g. itch.io) | Through the [relay](relay/README.md) on Cloudflare | Internet; phones on **any** network |

Built from two projects:
- [godot-phone-controller](https://github.com/jalaad/godot-phone-controller): phone page, WebSocket server, QR code
- [pvp-arena](https://github.com/jalaad/pvp-arena): the arena game, fighters and rules

## Play

1. Open this folder in Godot 4.7, press Play and pick **Play on this screen**. Allow the Windows Firewall prompt for **Private networks**.
   (In the browser build there's no firewall prompt; the QR code appears once the relay connects.)
2. Each player scans the QR code with a phone (same Wi-Fi for desktop builds) and taps **Join**.
   The first phone becomes Player 1 (blue), the second Player 2 (pink); each phone recolours to match.
3. The match starts automatically once both phones join.

| Phone | Action |
|---|---|
| Drag on the left half | Move (360°) |
| ATTACK | Melee: 12 damage + knockback |
| SHOOT | Projectile: 7 damage, stopped by pillars |
| BLOCK (hold) | Hits from the front do 20% damage; you move slowly |
| DASH | Quick burst; you can't be hurt mid-dash |
| NEXT ROUND | Start the next round after a knockout |

Phones vibrate when you're hit, win or get knocked out (Android; iPhones can't vibrate from a browser).

**Keyboard works too**, for either player at any time, even alongside a phone:
P1 = WASD + K attack, L shoot, J block, I dash. P2 = Arrows + Numpad 5 attack, 6 shoot, 4 block, 8 dash.
Press **Enter** in the lobby to start without phones, **Tab** to bring the QR code back up.

## How it fits together

```
project.godot                 input map + PhoneControllers and Session autoloads
phone_controller/
  controller.html             the phone page (buttons: attack/shoot/block/dash/start)
  phone_controller_server.gd  serves the page (HTTP 8080) + receives input (WebSocket 8081)
  qr_code.gd                  QR code generator
scenes/  menu.tscn (start screen) · main.tscn · fighter.tscn · bullet.tscn
scripts/
  menu.gd                     start screen, match-code keypad, ?join= links
  session.gd                  what was picked in the menu (mode, code)
  main.gd                     lobby, rounds, HUD; online host (snapshots) and guest (prediction, interpolation)
  online_guest.gd             guest networking: relay + WebRTC direct link
  touch_controls.gd           on-screen joystick and buttons (multi-touch)
  fighter.gd                  reads keyboard AND its phone (phone_id); movement + the 4 actions
  bullet.gd
```

- Each phone button name on the page (`data-btn="attack"` etc.) matches the fighter action name, so adding a
  button is one line in `controller.html` plus handling it in `fighter.gd`.
- Balance numbers are constants at the top of `scripts/fighter.gd`.
- If a phone drops (screen lock, Wi-Fi blip) it keeps its fighter for 30 seconds and reconnects by itself.

## Troubleshooting

- **Phone can't open the page:** allow Godot through Windows Firewall (Private), and make sure the phone
  isn't on a guest network. If the QR shows the wrong IP (VPN/virtual adapters), set `host_override` on the
  `PhoneControllers` autoload.
- **Exporting:** add `phone_controller/*.html` to *Export → Resources → Filters to export non-resource files*.
