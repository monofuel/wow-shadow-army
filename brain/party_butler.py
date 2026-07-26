"""Auto-accept party invites from an allowlisted inviter (the human).

Standing butler loop for one seat: watch the frame, and the moment a party
invite is pending FROM an allowlisted character, submit `accept_party`.

Doctrine (docs/party-formation.md): bots never ADDRESS the human's character,
but accepting the human's own invite is reactive and human-initiated —
`accept_party` is generically masked from `observation.party.invite_pending`
alone, no roster or dungeon goal needed. The allowlist keeps the bot from
auto-joining anyone else.

Usage (per seat, from wow-shadow-army):
    uv run --project ../coworld-vanilla-wow python -m brain.party_butler \
        --slot 2 --character Shadowfel --accept-from Murist

Runs forever (default); --max-seconds for bounded runs. One process per seat.
"""

from __future__ import annotations

import argparse
import functools
import sys
import time
from typing import Any

from brain.upstream import ensure_upstream_on_path

ensure_upstream_on_path()

from player.sdk.nim_control import (  # noqa: E402
    ActionSelectionRequest,
    FactorizedAction,
    GoalRequest,
    NimControlClient,
    NimControlRequestError,
)

print = functools.partial(print, flush=True)  # noqa: A001


def should_accept(
    invite_pending: bool, invite_from: str, allowlist: list[str]
) -> bool:
    """Pure decision: accept only a pending invite from an allowlisted name."""
    if not invite_pending:
        return False
    return invite_from.strip().lower() in [n.strip().lower() for n in allowlist]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--slot", type=int, required=True)
    parser.add_argument("--character", required=True)
    parser.add_argument(
        "--accept-from",
        default="Murist",
        help="comma-separated inviter allowlist (default: Murist)",
    )
    parser.add_argument("--cadence", type=float, default=1.5)
    parser.add_argument("--max-seconds", type=float, default=0.0)
    args = parser.parse_args()
    allowlist = [n for n in args.accept_from.split(",") if n.strip()]

    started = time.monotonic()
    with NimControlClient(slot=args.slot, timeout_seconds=10.0) as client:
        status = client.status()
        print(
            f"[butler] slot={args.slot} phase={status.phase} "
            f"goal={status.goal.id if status.goal else None} "
            f"accept-from={allowlist}"
        )
        if status.goal is None:
            # accept_party needs any installed goal; install a passive one.
            try:
                status = client.submit_goal(
                    GoalRequest(
                        goal_id="party-butler",
                        goal_kind="leveling",
                        selection_mode="external",
                        leader_name=args.character,
                        party_members=[args.character],
                        expected_slot=args.slot,
                        expected_revision=status.revision,
                    )
                )
                print(f"[butler] passive goal installed rev={status.revision}")
            except NimControlRequestError as exc:
                print(f"[butler] goal install failed: {exc}")
                return 2

        in_party_reported = False
        while args.max_seconds <= 0 or time.monotonic() - started < args.max_seconds:
            try:
                frame: Any = client.status(include_environment_frame=True)
            except Exception as exc:  # noqa: BLE001
                print(f"[butler] frame error: {exc}")
                time.sleep(max(args.cadence, 3.0))
                continue
            party = frame.observation.party
            if party.members and not in_party_reported:
                print(f"[butler] in party with: {[m.name for m in party.members]}")
                in_party_reported = True
            elif not party.members:
                in_party_reported = False
            if should_accept(party.invite_pending, party.invite_from, allowlist):
                action = FactorizedAction(kind="accept_party")
                if not frame.action_ready or not frame.allows_action(action):
                    time.sleep(0.5)
                    continue
                print(f"[butler] invite from {party.invite_from!r}: accepting")
                try:
                    client.select(
                        ActionSelectionRequest(
                            action=action,
                            frame_id=frame.frame_id,
                            observed_tick=frame.observed_tick,
                            expected_slot=args.slot,
                            expected_revision=frame.revision,
                        )
                    )
                except NimControlRequestError as exc:
                    print(f"[butler] accept rejected: {exc}")
                time.sleep(1.0)
                try:
                    settled = client.last_settlement()
                    print(
                        f"[butler] settled success={getattr(settled, 'success', None)} "
                        f"msg={getattr(settled, 'message', '')!r}"
                    )
                except Exception as exc:  # noqa: BLE001
                    print(f"[butler] settle read error: {exc}")
            elif party.invite_pending:
                print(
                    f"[butler] ignoring invite from non-allowlisted "
                    f"{party.invite_from!r}"
                )
                time.sleep(args.cadence)
            time.sleep(args.cadence)
    print("[butler] max-seconds reached")
    return 0


if __name__ == "__main__":
    sys.exit(main())
