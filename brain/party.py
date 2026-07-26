"""Party formation over `vanilla_wow.nim_control.v1`.

Why this module exists: `invite_party` is only ever unmasked when the Nim
controller's own recommended action is an invite (upstream
`player/contract/environment_frame.nim:1230` is the only route that enables
that kind). The controller only recommends one when a **dungeon** goal
carries a declared roster whose `leader_name` is this seat
(`player/behavior/dungeon.nim:1306`-`1319` → `player/behavior/party.nim:244`).
So "form a party" is: install the right goal, then take the offered action.

`accept_party` is different — it is unmasked purely from
`observation.party.invite_pending`
(`player/contract/environment_frame.nim:1168`-`1169`), so any seat with *any*
installed goal can accept an invite from anyone, including a stranger.

See `docs/party-formation.md` for the full evidence trail.
"""

from __future__ import annotations

import argparse
import time
from dataclasses import dataclass, field

from brain.upstream import (
    ActionSelectionRequest,
    ControlDirective,
    FactorizedAction,
    GoalRequest,
    NimControlClient,
)
from player.sdk.nim_control import POLICY_ACTION_KINDS

# Only dungeon task id the Nim goal validator accepts
# (`player/behavior/dungeon.nim:54`, enforced at
# `player/reference_player/runtime/nim_control_server.nim:900`).
DUNGEON_TASK_ID = "ragefire-chasm-clear"
INVITE = "invite_party"
ACCEPT = "accept_party"


def enabled_kinds(frame) -> list[str]:
    """Action kinds this frame's mask admits, by contract name."""
    return [
        name
        for index, name in enumerate(POLICY_ACTION_KINDS)
        if index < len(frame.action_mask.kind) and frame.action_mask.kind[index]
    ]


@dataclass
class SeatReport:
    slot: int
    name: str = ""
    in_group: bool = False
    leader_name: str = ""
    members: list[str] = field(default_factory=list)
    invite_pending: bool = False
    invite_from: str = ""
    mask_kinds: list[str] = field(default_factory=list)
    texts: list[str] = field(default_factory=list)
    settlements: list[str] = field(default_factory=list)


def install_leader_goal(
    slot: int, leader: str, members: list[str], goal_id: str
) -> int:
    """Dungeon goal with a declared roster — the only thing that makes the
    controller recommend `invite_party`."""
    with NimControlClient(slot=slot) as client:
        status = client.status()
        new = client.submit_goal(
            GoalRequest(
                goal_id=goal_id,
                goal_kind="dungeon",
                task_id=DUNGEON_TASK_ID,
                role="leader",
                leader_name=leader,
                party_members=members,
                selection_mode="external",
                expected_slot=slot,
                expected_revision=status.revision,
            )
        )
        return new.revision


def install_member_goal(slot: int, goal_id: str) -> int:
    """Any goal makes the seat emit frames; a bare external leveling goal is
    the least opinionated one. Without a goal the frame stays empty and
    `accept_party` can never be offered."""
    with NimControlClient(slot=slot) as client:
        status = client.status()
        new = client.submit_goal(
            GoalRequest(
                goal_id=goal_id,
                goal_kind="leveling",
                selection_mode="external",
                expected_slot=slot,
                expected_revision=status.revision,
            )
        )
        return new.revision


def _take_offered(client, slot: int, kind: str, frame) -> str | None:
    """Select the offered action of `kind`, echoing the recommended factors.

    The recipient factor is a text-pool index owned by the frame; an external
    policy cannot invent a name, so we reuse the controller's recommendation
    (`player/contract/environment_frame.nim:780`-`782`, `:1381`).
    """
    recommended = frame.recommended_action
    action = FactorizedAction(
        kind=kind,
        recipient=(
            recommended.recipient
            if recommended is not None and recommended.kind == kind
            else 0
        ),
    )
    if not frame.allows_action(action):
        return None
    client.select(
        ActionSelectionRequest(
            action=action,
            frame_id=frame.frame_id,
            observed_tick=frame.observed_tick,
            expected_slot=slot,
            expected_revision=frame.revision,
        )
    )
    for _ in range(20):
        time.sleep(1.0)
        settled = client.last_settlement()
        if settled and settled.action_kind == kind:
            return f"{kind}: success={settled.success} {settled.message}"
    return f"{kind}: selected, no settlement observed"


def drive_seat(slot: int, kind: str, timeout_seconds: float) -> SeatReport:
    """Poll one seat until `kind` is unmasked, then take it."""
    report = SeatReport(slot=slot)
    deadline = time.monotonic() + timeout_seconds
    with NimControlClient(slot=slot) as client:
        while True:
            frame = client.status(include_environment_frame=True)
            party = frame.observation.party
            report.name = frame.observation.name
            report.in_group = party.in_group
            report.leader_name = party.leader_name
            report.members = [m.name for m in party.members]
            report.invite_pending = party.invite_pending
            report.invite_from = party.invite_from
            report.mask_kinds = enabled_kinds(frame)
            report.texts = [t.value for t in frame.bindings.texts]
            if kind in report.mask_kinds:
                outcome = _take_offered(client, slot, kind, frame)
                if outcome:
                    report.settlements.append(outcome)
                    return report
            if time.monotonic() >= deadline:
                return report
            time.sleep(1.0)


def cancel(slot: int) -> None:
    with NimControlClient(slot=slot) as client:
        status = client.status()
        client.directive(
            ControlDirective(
                directive="cancel",
                expected_slot=slot,
                expected_revision=status.revision,
            )
        )


def _print(report: SeatReport) -> None:
    print(
        f"slot {report.slot} ({report.name or '?'}): in_group={report.in_group} "
        f"leader={report.leader_name or '-'} members={report.members} "
        f"invite_pending={report.invite_pending} from={report.invite_from or '-'}"
    )
    print(f"  mask kinds: {', '.join(report.mask_kinds) or '(empty frame)'}")
    if report.texts:
        print(f"  text pool: {report.texts}")
    for line in report.settlements:
        print(f"  settled: {line}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--leader-slot", type=int, required=True)
    parser.add_argument("--leader", required=True, help="leader character name")
    parser.add_argument(
        "--members",
        required=True,
        help="full roster, comma separated, leader included",
    )
    parser.add_argument(
        "--member-slots",
        default="",
        help="comma separated slots of OUR seats that should accept the invite; "
        "omit for members we do not control (strangers/humans accept manually)",
    )
    parser.add_argument("--goal-id", default="party-formation")
    parser.add_argument("--timeout", type=float, default=45.0)
    parser.add_argument(
        "--keep-goals",
        action="store_true",
        help="leave goals installed instead of cancelling after formation",
    )
    args = parser.parse_args(argv)

    roster = [name.strip() for name in args.members.split(",") if name.strip()]
    member_slots = [
        int(value) for value in args.member_slots.split(",") if value.strip()
    ]

    for slot in member_slots:
        install_member_goal(slot, f"{args.goal_id}-member-{slot}")
    install_leader_goal(args.leader_slot, args.leader, roster, args.goal_id)
    time.sleep(3.0)

    _print(drive_seat(args.leader_slot, INVITE, args.timeout))
    for slot in member_slots:
        _print(drive_seat(slot, ACCEPT, args.timeout))

    if not args.keep_goals:
        for slot in [args.leader_slot, *member_slots]:
            cancel(slot)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
