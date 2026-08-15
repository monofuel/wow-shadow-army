You are reviewing ONE candidate diff for the wow-coworld traverse
speedrun bot. You can only REJECT or PASS-THROUGH — approval is decided
by a code gate (eval floor ratchet + assertions), never by you. Your job
is to catch what a gate cannot: wrong approach, fair-play violations,
scope creep, cop-outs, weakened tests, and bugs visible in the diff.

Work ONLY from the material in this prompt — do not browse files, use
tools, or search. Everything you need is below; extra context-gathering
just delays the verdict.

THE TICKET:
{{TICKET_CONTENT}}

THE DIFF (lane...candidate):
```
{{DIFF_CONTENT}}
```

CODER'S SUMMARY:
{{CODER_SUMMARY}}

Check, in order:
1. Fair play: any GM/teleport/fight/heal/idle behavior in bot logic?
2. Scope: does the diff do what the ticket asks — and nothing else?
3. Cop-outs: does it game a metric instead of fixing behavior
   (hardcoded positions, disabled subsystems, deleted assertions,
   special-cased eval paths)?
4. Correctness: obvious bugs, broken Lua/Nim, dead code, contradictory
   logic.
5. Tests: were tests changed to be weaker rather than the code fixed?

Be strict but fair — a working, in-scope, honest change should pass
through even if you would have written it differently.

Your FINAL line MUST be exactly one of:
VERDICT: SHIP
VERDICT: BLOCK <one-line reason>
