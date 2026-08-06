# map-browser

- `make map-browser`

## notes

- do not modify coworld-vanilla-wow (used for server stuff) or coworld-vanilla-wow-fork (used for client stuff)
- we can import them and use functions but do not modify them, there's no reason to be making upstream changes for our map browser.
- the map browser is a local tool for us.

## tasks

- finish implementing a nice pretty map viewer
  - [ ] nice camera controls
  - [ ] looks decent
  - [ ] capable of rendering the entire game world as one seamless entity for easy scrolling
- [ ] build a rudimentary waypoint system between cities
- [ ] build a system for handling things like the great lifts (elavator) in thousand needles
- [ ] figure out zone shenanigans for things like where cities occupy a different space not part of the regular game world (eg: cities that are too big for the actual geography of the game map)
