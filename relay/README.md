# Relay (Cloudflare Workers)

Pairs a game with the devices joining it, by room code. A browser game can't run a server, so both
sides connect *out* to this relay. It's used for:

- **Phone controllers** with the browser build (GitHub Pages, itch.io): phones open the controller page
  from the relay and send their input through it.
- **Online matches** (phone vs phone, any build): the guest's game joins the host's room just like a phone
  controller would. In browsers the relay also carries the WebRTC offer/answer so the two phones can open
  a direct link; if that fails, input and game state keep flowing through the relay.

```
game / match host ──────► /ws/host/CODE ─┐
                                         ├─ Room CODE (Durable Object) forwards messages both ways
phone / match guest ────► /ws/phone/CODE ┘
phone opens               /?r=CODE        ── the controller page (copied from ../phone_controller/controller.html)
```

Live at: `https://pvp-phone-relay.pvp-phone-relay.workers.dev` (`DEFAULT_RELAY_URL` in
`phone_controller/phone_controller_server.gd`; if you rename the Worker or subdomain, change it there).

## Deploy / update

Needs Node.js and a (free) Cloudflare account.

```bash
cd relay
npm install
npx wrangler login     # once; approve in the browser
npm run deploy         # copies the phone page into public/ and deploys
```

Redeploy whenever `phone_controller/controller.html` changes, so phones get the new page.

Local testing: `npm run dev` serves the relay on http://127.0.0.1:8787. Point the game at it with an
`override.cfg` in the project root (don't commit it):

```ini
[phone_controllers]
mode="relay"
relay_url="ws://127.0.0.1:8787"
```

## Costs

Cloudflare's free plan covers casual use. Each room is a Durable Object that stays awake while a game
is connected; the free tier's daily Durable Object allowance is roughly a day's worth of one room being
open, spread across however many games are running. See Cloudflare's current Workers pricing page for
exact limits.

## Notes

- Rooms are 4-character codes chosen by the game; if one is taken the game picks another. The match code
  players type is this room code.
- If the game disconnects, phones see "Waiting for the game…" (an online guest shows *reconnecting*) and
  rejoin automatically, in the same player slot, when it reconnects with the same code.
- Up to 8 phones per room; messages over 4096 characters are dropped (game messages and WebRTC offers
  are well under that).
- Latency is roughly your network's ping to Cloudflare; unstable Wi-Fi shows up as stutter.
