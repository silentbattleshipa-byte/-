# ===== ARSENAL DATABASE ONLINE - WebSocket中継サーバー（2人対戦用）=====
# 使い方: PowerShell でこのファイルを実行してから、HTMLの「ONLINE対戦」で
#          片方が「ルーム作成」→ 表示されたコードをもう片方が「参加」に入力。
# 2つのブラウザ/タブ/PC(同じLAN内は localhost をPCのIPに変更)で開けば対戦できます。
# ポート: 8080

$source = @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Net;
using System.Net.WebSockets;
using System.Text;
using System.Threading;

public static class ArsenalServer {
  class Room {
    public WebSocket Host; public WebSocket Guest;
    public string HostDeck; public string GuestDeck; public bool Started; public bool HostReady; public bool GuestReady;
  }
  static ConcurrentDictionary<string, Room> rooms = new ConcurrentDictionary<string, Room>();
  static ConcurrentDictionary<WebSocket, string> sockRoom = new ConcurrentDictionary<WebSocket, string>();
  static Random rng = new Random();

  static void Send(WebSocket ws, string json) {
    try {
      if (ws != null && ws.State == WebSocketState.Open)
        ws.SendAsync(new ArraySegment<byte>(Encoding.UTF8.GetBytes(json)), WebSocketMessageType.Text, true, CancellationToken.None).GetAwaiter().GetResult();
    } catch { }
  }

  static void TryMatchStart(Room r) {
    if (r.Started) return;
    if (r.HostDeck != null && r.GuestDeck != null && r.HostReady && r.GuestReady && r.Host != null && r.Guest != null) {
      r.Started = true;
      long startAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + 10000;
      string hostMsg = "{\"type\":\"matchStart\",\"hostDeck\":" + r.HostDeck + ",\"guestDeck\":" + r.GuestDeck + ",\"startAt\":" + startAt + "}";
      // 双方に同じJSON（hostDeck/guestDeck の区別はクライアント側でroleにより判定）
      Send(r.Host, hostMsg);
      Send(r.Guest, hostMsg);
      Console.WriteLine("matchStart sent (both READY)");
    }
  }

  public static void Handle(WebSocket ws, string text) {
    string type = null, room = null;
    // 軽量JSONフィールド抽出（完全パース不要）
    var m1 = System.Text.RegularExpressions.Regex.Match(text, "\"type\"\\s*:\\s*\"([^\"]+)\"");
    if (m1.Success) type = m1.Groups[1].Value;
    var m2 = System.Text.RegularExpressions.Regex.Match(text, "\"room\"\\s*:\\s*\"([^\"]+)\"");
    if (m2.Success) room = m2.Groups[1].Value;

    switch (type) {
      case "create": {
        string code = rng.Next(100000, 999999).ToString();
        while (rooms.ContainsKey(code)) code = rng.Next(100000, 999999).ToString();
        rooms[code] = new Room { Host = ws };
        sockRoom[ws] = code;
        Send(ws, "{\"type\":\"roomCreated\",\"room\":\"" + code + "\"}");
        Console.WriteLine("room " + code + " created");
        break;
      }
      case "join": {
        Room r;
        if (room == null || !rooms.TryGetValue(room, out r) || r.Guest != null) {
          Send(ws, "{\"type\":\"error\",\"message\":\"ルームが見つからないか満室です\"}");
          break;
        }
        r.Guest = ws; sockRoom[ws] = room;
        Send(ws, "{\"type\":\"roomJoined\",\"room\":\"" + room + "\"}");
        Send(r.Host, "{\"type\":\"peerJoined\"}");
        Console.WriteLine("room " + room + " joined");
        break;
      }
      case "ready": {
        string code;
        if (!sockRoom.TryGetValue(ws, out code)) break;
        Room r;
        if (!rooms.TryGetValue(code, out r)) break;
        int start = text.IndexOf("\"deck\":") + 7;
        string deckJson = text.Substring(start).Trim();
        if (deckJson.EndsWith("}")) {
          int last = deckJson.LastIndexOf('}');
          deckJson = deckJson.Substring(0, last).Trim();
        }
        if (r.Host == ws) { r.HostDeck = deckJson; r.HostReady = true; if (r.Guest != null) Send(r.Guest, "{\"type\":\"peerReady\"}"); }
        else if (r.Guest == ws) { r.GuestDeck = deckJson; r.GuestReady = true; if (r.Host != null) Send(r.Host, "{\"type\":\"peerReady\"}"); }
        Console.WriteLine("player ready");
        TryMatchStart(r);
        break;
      }
      case "deck": {
        string code;
        if (!sockRoom.TryGetValue(ws, out code)) break;
        Room r;
        if (!rooms.TryGetValue(code, out r)) break;
        if (r.Host == ws) {
          int start = text.IndexOf("\"deck\":") + 7;
          string deckJson = text.Substring(start).Trim();
          if (deckJson.EndsWith("}")) {
            int last = deckJson.LastIndexOf('}');
            deckJson = deckJson.Substring(0, last).Trim();
          }
          r.HostDeck = deckJson;
        } else if (r.Guest == ws) {
          int start = text.IndexOf("\"deck\":") + 7;
          string deckJson = text.Substring(start).Trim();
          if (deckJson.EndsWith("}")) {
            int last = deckJson.LastIndexOf('}');
            deckJson = deckJson.Substring(0, last).Trim();
          }
          r.GuestDeck = deckJson;
        }
        TryMatchStart(r);
        break;
      }
      default: {
        // action / snapshot / finish などは相手へ中継
        string code;
        if (!sockRoom.TryGetValue(ws, out code)) break;
        Room r;
        if (!rooms.TryGetValue(code, out r)) break;
        if (r.Host == ws && r.Guest != null) Send(r.Guest, text);
        else if (r.Guest == ws && r.Host != null) Send(r.Host, text);
        break;
      }
    }
  }

  public static void Cleanup(WebSocket ws) {
    string code;
    if (sockRoom.TryRemove(ws, out code)) {
      Room r;
      if (rooms.TryGetValue(code, out r)) {
        WebSocket peer = r.Host == ws ? r.Guest : r.Host;
        if (peer != null) Send(peer, "{\"type\":\"peerLeft\"}");
        rooms.TryRemove(code, out r);
        Console.WriteLine("room " + code + " closed");
      }
    }
    try { ws.Dispose(); } catch { }
  }

  static void ClientLoop(WebSocket ws) {
    Console.WriteLine("client connected");
    var buffer = new byte[262144];
    try {
      while (ws.State == WebSocketState.Open) {
        var ms = new System.IO.MemoryStream();
        bool closed = false;
        while (true) {
          var res = ws.ReceiveAsync(new ArraySegment<byte>(buffer), CancellationToken.None).GetAwaiter().GetResult();
          if (res.MessageType == WebSocketMessageType.Close) { closed = true; break; }
          ms.Write(buffer, 0, res.Count);
          if (res.EndOfMessage) break;
        }
        if (closed) break;
        string text = Encoding.UTF8.GetString(ms.ToArray());
        ms.Dispose();
        try { Handle(ws, text); } catch (Exception e) { Console.WriteLine("handler error: " + e.Message); }
      }
    } catch (Exception) { /* 急な切断 */ }
    Cleanup(ws);
    Console.WriteLine("client disconnected");
  }

  public static void Run(int port) {
    var listener = new HttpListener();
    listener.Prefixes.Add("http://localhost:" + port + "/");
    listener.Start();
    Console.WriteLine("ONLINE server listening on ws://localhost:" + port);
    while (listener.IsListening) {
      var ctx = listener.GetContext();
      if (!ctx.Request.IsWebSocketRequest) { try { ctx.Response.StatusCode = 400; ctx.Response.Close(); } catch { } continue; }
      var ws = ctx.AcceptWebSocketAsync(null).GetAwaiter().GetResult().WebSocket;
      var t = new Thread(() => ClientLoop(ws));
      t.IsBackground = true;
      t.Start();
    }
  }
}
'@
Add-Type -TypeDefinition $source -Language CSharp
[ArsenalServer]::Run(8080)


