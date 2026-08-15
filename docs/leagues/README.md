# League standings tracker

One file per league, append-only snapshot tables — our position over
time, the leader's score, and which of our policy versions held the
champion seat when the row was taken.

Vocabulary (Softmax): "champion" = OUR active policy in the league (one
per player; other uploads sit inactive). Leaderboard rank is separate —
champion says which of our versions is racing, rank says how it's doing.

Row discipline: add a row whenever we observe the standings (submission,
round result, or manual check). Never rewrite old rows; corrections get
a new row with a note.

| file | league | scoring |
|---|---|---|
| race.md | Race Wow (kalimdor-south-to-north) | farthest northing from spawn (world X + 9187) within 45 sim-min at 10x |
