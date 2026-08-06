# map-browser

- `make map-browser`

## notes

- do not modify coworld-vanilla-wow (used for server stuff) or coworld-vanilla-wow-fork (used for client stuff)
- we can import them and use functions but do not modify them, there's no reason to be making upstream changes for our map browser.
- the map browser is a local tool for us.

- the upstream nim client now has built-in navigational features. we should rely on these in our map viewer to be accurate to what a bot would really do.

## tasks

- finish implementing a nice pretty map viewer
  - [ ] nice camera controls
  - [ ] looks decent
  - [ ] capable of rendering the entire game world as one seamless entity for easy scrolling
- [ ] build a rudimentary waypoint system between cities
  - use the upstream nim client (or well, the coworld-vanilla-wow-fork version, basically don't re-implment any existing nav work)
- [ ] build a system for handling special things like the great lifts (elavator) in thousand needles
  - a bot cannot walk across here, but they can take the lifts, so it's more like a 'logical' connection rather than a walking nav point.
  - there are probably many more examples but we can deal with them in the future.
- [ ] figure out zone shenanigans for things like where cities occupy a different space not part of the regular game world (eg: cities that are too big for the actual geography of the game map)

- [ ] build a visualizer for previous runs
  - it would be cool if the map explorer gave us a list of previous funs (eg: traverse scenario runs) and could plot them on top of the 3d map. then we can see how they line up with waypoints and how far the bot gets.
