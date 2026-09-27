# Relay (Cloudflare Workers)

Pairs a game with the devices joining it, by room code. A browser game can't run a server, so both
sides connect *out* to this relay. It's used for:

- **Phone controllers** with the browser build (GitHub Pages, itch.io), and any time the game calls
  `PhoneControllers.start("relay")`: phones open the controller page from the relay and send their
  input through it.
- **Online matches** (phone vs phone, any build): the guest's game joins the host's room just like a
  phone controller would. In browsers the relay also carries the WebRTC offer/answer so the two phones
  can open a direct link; if that fails, input and game state keep flowing through the relay.

```
game / match host ──────► /ws/host/CODE ─┐
                                         ├─ Room CODE (Durable Object) forwards messages both ways
phone / match guest ────► /ws/phone/CODE ┘
phone opens               /?r=CODE        ── the controller page the game uploaded for room CODE
                                             (or the built-in copy in public/, see below)
```

Deployed twice, on two Cloudflare accounts (each has its own free daily allowance). Both addresses are
constants in `phone_controller/phone_controller_server.gd`:

| Constant | Address |
|---|---|
| `RELAY_MAIN` | `https://pvp-phone-relay.pvp-phone-relay.workers.dev` |
| `RELAY_BACKUP` | `https://pvp-phone-relay.gamejam-relay.workers.dev` |

`DEFAULT_RELAY_URL` says which one the game uses (currently `RELAY_BACKUP`, while the main account's
allowance recovers). Switch by changing that one word; see the next section for switching without a
rebuild. Deploy code changes to **both** (see "Deploy / update").

## Switching to another relay (and back)

The game picks its relay in this order (`_pick_relay_url()` in `phone_controller_server.gd`); the first
one set wins:

| Where | How | Needs a rebuild? |
|---|---|---|
| Web build | add `?relay=HOST` to the game's address, e.g. `https://jalaad.github.io/GameJam-PvP-Online/?relay=pvp-phone-relay.OTHER.workers.dev` | No; remove it to go back |
| Desktop / editor | environment variable `PHONE_RELAY_URL=HOST` before starting Godot or the game | No |
| Any build | Project Setting `phone_controllers/relay_url` (or an `override.cfg` next to the game) | Editor: no. Exports: re-export |
| Default | `DEFAULT_RELAY_URL := RELAY_MAIN` / `RELAY_BACKUP` in `phone_controller_server.gd` | Yes (one word) |

`HOST` can be a bare host name or a full `wss://…` URL. Phones follow automatically (the QR code points
at the relay in use), and invite links carry `&relay=…` when it isn't the default, so a friend's game
joins the same relay.

To run a relay on a **second Cloudflare account** without logging out of the first, give wrangler a
separate credentials folder (PowerShell):

```powershell
$env:XDG_CONFIG_HOME = "C:\path\to\wrangler-account2"   # any folder; keep it out of git
npx wrangler login        # sign in with the other account
npm run deploy            # prints https://pvp-phone-relay.<that account's subdomain>.workers.dev
```

Without `XDG_CONFIG_HOME` set, wrangler uses the original login again. Each Cloudflare account has its own
free daily allowance.

## Which controller page phones get

When the game opens a room it uploads its own `phone_controller/controller.html`
(`{"t":"_page","html":…}` over its WebSocket, see `upload_page_to_relay` in
`phone_controller_server.gd`), and the relay serves that page at `/?r=CODE` with `Cache-Control: no-store`.
So:

- **Edit `controller.html`, restart the game (re-export builds), and phones get the new page.** No relay
  redeploy needed.
- One relay can serve many different games, each with its own controller page.
- `public/index.html` (copied from `../phone_controller/controller.html` by `npm run deploy`) is only a
  fallback for games that don't upload a page (older versions of `phone_controller_server.gd`).

## Deploy / update

Needs Node.js and a (free) Cloudflare account. Only needed when `src/index.js` or `wrangler.jsonc`
change, or to set up your own relay.

```bash
cd relay
npm install
npx wrangler login     # once; approve in the browser
npm run deploy         # copies the fallback phone page into public/ and deploys
```

That deploys to the account wrangler is logged in to (`RELAY_MAIN`). For `RELAY_BACKUP`, which is on the
second account, point wrangler at that account's login folder first (PowerShell; the folder is the one
used when logging in to that account, see "Switching to another relay"):

```powershell
$env:XDG_CONFIG_HOME = "C:\path\to\wrangler-account2"; npm run deploy
Remove-Item Env:XDG_CONFIG_HOME      # back to the main account
```

**Your own relay for another game:** change `"name"` in `wrangler.jsonc` first (e.g. `"my-game-relay"`),
deploy, and set `DEFAULT_RELAY_URL` to the `wss://…workers.dev` address it prints. Deploying with an
existing name to the same Cloudflare account **replaces** that relay.

Local testing: `npm run dev` serves the relay on http://127.0.0.1:8787. Point the game at it with an
`override.cfg` in the project root (don't commit it):

```ini
[phone_controllers]
mode="relay"
relay_url="ws://127.0.0.1:8787"
```

## Costs and the free plan's daily limit

The free Workers plan allows **100,000 requests a day** (resets at 00:00 UTC). Every page load and every
WebSocket connect is a request; messages over an open connection are not. A match uses a handful, but
something that reconnects in a loop uses them up fast. When the limit is hit, *everything* on the relay
answers **429 / Cloudflare error 1027** ("temporarily rate limited") until the reset: phones can't join,
online matches can't connect.

To stay well under it, every client backs off when the other side is gone:

| Client | Retries | Gives up |
|---|---|---|
| Phone controller page | 0.5 s growing to 4 s, then to 30 s after a minute; paused while the page is hidden | after 10 minutes (shows the Join button) |
| Online guest (`OnlineGuest`) | 1 s growing to 15 s | after 2 minutes (the menu shows why) |
| Game / match host (`PhoneControllers`) | 2 s growing to 30 s | never (the lobby shows the status) |

Still, close controller pages and game tabs you're not using. For heavy use, the Workers Paid plan
(10 million requests a month) removes the problem. Each room is also a Durable Object, which has its own
free allowance; see Cloudflare's current pricing page for exact limits.

## Notes

- Rooms are 4-character codes chosen by the game; if one is taken the game picks another. The match code
  players type is this room code.
- If the game disconnects, phones see "Waiting for the game…" (an online guest shows *reconnecting*) and
  rejoin automatically, in the same player slot, when it reconnects with the same code. The room keeps its
  uploaded page meanwhile.
- Up to 8 devices per room. Forwarded messages over 4096 characters are dropped (game messages and WebRTC
  offers are well under that); an uploaded page can be up to 512 KB.
- Latency is roughly your network's ping to Cloudflare; unstable Wi-Fi shows up as stutter.
