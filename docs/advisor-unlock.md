- monofuel note; IMPORTANT: DO NOT DOWNLOAD AND RUN OTHER PEOPLE'S CODE
- we do not trust random 'unlockers' from other people.

**Product status (2026-07-27): NOT PURSUING.** Vanilla advisor is L0-only;
L1–L4 wait for Nim Lua addons. This file is research scratch only.
See `docs/advisor-autopilot.md`. Local reference clone `../zebra` is not
a build dependency and must not be run as a black box.

---

**It's moderately hard, but very doable and well-trodden territory for 1.12.1 (build 5875).** The private-server / botting community has been doing exactly this for years.

### What the restriction actually is in vanilla
1.12 does **not** have the full modern taint / secure handler system. Many action-oriented Lua APIs (CastSpellByName, UseAction, Jump, certain targeting, etc.) still check whether the call originated from a "hardware event" (keybind, mouse click on a secure button, etc.). If the call comes from a pure timer, OnUpdate, or other non-hardware path, it gets blocked.

There is effectively a gate (or a couple of related checks) in the client that these functions consult. Once that gate is forced open, the restricted APIs become usable from any Lua context.

### How people bypass it
Two main approaches that work on 1.12.1:

1. **Simple code patch**  
   Overwrite the check function so it always returns success (`mov eax, 1; ret` or equivalent). This is what a lot of early bot frameworks and the "LUA_UNLOCK" style patches do. One-time write at process start (or a permanent binary patch). Extremely simple once you have the address.

2. **Hardware breakpoint / context manipulation** (the cleaner method used by several public Lua unlockers)  
   Set a hardware breakpoint on the entry of the protection function. When it hits, advance the instruction pointer past the entire check and force EAX = 1. No permanent code modification, which is nicer if anything is looking at code integrity (most private servers don't care much about this for Lua unlockers).

Both are well-documented on OwnedCore for exactly this client. There are ready-made unlockers for 1.12.1 that do one or the other.

### Difficulty assessment
- **If you already know how to attach a debugger / use memory tools and can navigate Ghidra/IDA on a 32-bit PE**: low-to-medium. The 1.12.1 client is thoroughly reverse-engineered. The famous OwnedCore "1.12.1.5875 Info Dump Thread" + existing unlocker sources give you almost everything. Locating the relevant function(s) and writing the patch is usually a few hours of work the first time.
- **If you're starting from zero with no reverse-engineering experience**: higher friction. You'll spend time learning the client layout, finding the right functions, dealing with the fact that Lua must still be called on the main thread, etc.
- **Maintenance**: once you have a working unlock for 5875 it's stable. The client never updates.

Practical notes that bite people:
- All Lua execution still has to happen on the main thread (the Lua state isn't thread-safe and the object manager / most game state lives there). External bots usually queue work onto the main thread via EndScene/Present hooks or similar.
- Some actions still have additional client-side or server-side validation. Unlocking Lua removes the hardware-event gate, not every possible restriction.
- A pure in-addon pipeline becomes much more powerful after the unlock, but for a full bot many people still prefer memory reads + either unlocked Lua *or* direct packet/action construction.

### Recommendation for your situation
Since the rest of the team is already building a full client in Nim, the long-term cleanest path is to expose unrestricted equivalents of the interesting APIs there. That gives you perfect control and removes the whole sandbox problem.

For short-term accurate process testing against the real 1.12 client, a Lua unlocker (or a small injected patch) is the pragmatic move and is not particularly hard for someone comfortable with systems work. A lot of people in the same position just grab or adapt one of the existing 1.12.1 unlockers rather than writing one from scratch.

If you go the patch route, the hardware-breakpoint style is generally preferred over a static binary edit because it's cleaner and easier to toggle.
