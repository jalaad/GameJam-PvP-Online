// Relay between a Godot game (the "host") and the devices joining it: phone controllers, or the
// guest's copy of the game in an online match.
//
//   GET /?r=CODE           -> the phone controller page for room CODE: the page the game uploaded
//                             for that room, or the built-in copy (public/index.html) if it didn't
//   WS  /ws/host/CODE      -> the game opens room CODE
//   WS  /ws/phone/CODE     -> a device joins room CODE
//
// Each room is one Durable Object, so the game and all its devices meet in the same place.
// The relay doesn't understand the game protocol; it just wraps device messages with an id
// for the host and unwraps the host's replies. See phone_controller_server.gd for the format.
import { DurableObject } from "cloudflare:workers";

const MAX_PHONES = 8;
const MAX_MESSAGE_CHARS = 4096;        // any forwarded message (input, state, WebRTC setup)
const MAX_PAGE_CHARS = 512 * 1024;     // a controller page uploaded by the game
const ROOM_RE = /^[A-Za-z0-9]{4,8}$/;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const match = url.pathname.match(/^\/ws\/(host|phone)\/([A-Za-z0-9]{4,8})$/);
    if (match) {
      if (request.headers.get("Upgrade") !== "websocket") {
        return new Response("Expected a WebSocket upgrade", { status: 426 });
      }
      return roomStub(env, match[2]).fetch(request);
    }
    if (url.pathname === "/health") return new Response("ok");

    // The phone page: the room's own page if its game uploaded one, else the built-in copy.
    const room = url.searchParams.get("r") || "";
    if ((url.pathname === "/" || url.pathname === "/index.html") && ROOM_RE.test(room)) {
      const page = await roomStub(env, room).fetch(new Request(`${url.origin}/page`));
      if (page.ok) return page;
    }
    return env.ASSETS.fetch(request);
  },
};

function roomStub(env, code) {
  return env.ROOMS.get(env.ROOMS.idFromName(code.toUpperCase()));
}

// Uses plain (non-hibernating) WebSockets: a room stays in memory while anyone is connected,
// which keeps forwarding instant. Rooms only exist while a game is running.
export class Room extends DurableObject {
  host = null;          // the game's socket
  phones = new Map();   // cid -> device socket
  nextCid = 1;
  page = null;          // controller page uploaded by the game (HTML string), or null

  async fetch(request) {
    const [, first, role, code] = new URL(request.url).pathname.split("/");
    if (first === "page") {
      if (!this.page) return new Response("No page uploaded", { status: 404 });
      return new Response(this.page, {
        headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" },
      });
    }

    const room = code.toUpperCase();
    const [client, server] = Object.values(new WebSocketPair());
    server.accept();

    if (role === "host") {
      if (this.host) return this.refuse(server, client, 4009, "room_taken");
      this.host = server;
      server.addEventListener("message", (e) => this.fromHost(e.data));
      const hostGone = () => {
        if (this.host !== server) return;
        this.host = null;
        // Game went away: devices keep retrying and rejoin when it reconnects with the same code.
        // The page is kept, so a phone that reloads meanwhile still gets the game's page.
        for (const phone of this.phones.values()) close(phone, 4005, "host_left");
        this.phones.clear();
      };
      server.addEventListener("close", hostGone);
      server.addEventListener("error", hostGone);
      server.send(JSON.stringify({ t: "_room", room }));
    } else {
      if (!this.host) return this.refuse(server, client, 4004, "no_game");
      if (this.phones.size >= MAX_PHONES) return this.refuse(server, client, 4001, "full");
      const cid = this.nextCid++;
      this.phones.set(cid, server);
      server.addEventListener("message", (e) => this.fromPhone(cid, e.data));
      const phoneGone = () => {
        if (this.phones.get(cid) !== server) return;
        this.phones.delete(cid);
        send(this.host, JSON.stringify({ c: cid, closed: true }));
      };
      server.addEventListener("close", phoneGone);
      server.addEventListener("error", phoneGone);
      send(this.host, JSON.stringify({ c: cid, open: true }));
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  // Close right away with a reason, so the browser can show why.
  refuse(server, client, code, reason) {
    close(server, code, reason);
    return new Response(null, { status: 101, webSocket: client });
  }

  fromPhone(cid, data) {
    if (typeof data !== "string" || data.length > MAX_MESSAGE_CHARS) return;
    let msg;
    try { msg = JSON.parse(data); } catch { return; }
    send(this.host, JSON.stringify({ c: cid, m: msg }));
  }

  // {"c":ID,"m":{...}}        -> message to device ID
  // {"c":ID,"close":"reason"} -> disconnect it
  // {"t":"_page","html":"…"}  -> serve this HTML as the room's controller page (/?r=CODE)
  // "ping"                    -> "pong" keep-alive
  fromHost(data) {
    if (data === "ping") return send(this.host, "pong");
    if (typeof data !== "string" || data.length > MAX_PAGE_CHARS) return;
    let msg;
    try { msg = JSON.parse(data); } catch { return; }
    if (msg.t === "_page") {
      if (typeof msg.html === "string" && msg.html.length > 0) this.page = msg.html;
      return;
    }
    if (data.length > MAX_MESSAGE_CHARS) return;
    const phone = this.phones.get(msg.c);
    if (!phone) return;
    if (msg.close !== undefined) {
      this.phones.delete(msg.c);
      close(phone, 4001, String(msg.close).slice(0, 100));
    } else if (msg.m !== undefined) {
      send(phone, JSON.stringify(msg.m));
    }
  }
}

function send(ws, text) {
  try { ws?.send(text); } catch {}
}

function close(ws, code, reason) {
  try { ws.close(code, reason); } catch {}
}
