# client ticket iteration workflow

- Use a workflow to implement tickets / issues / checkboxes

- use parallel independent agents to plan the work.
  - see if we need additional data in logs
  - see if we need additional data in the ClientView to act on
  - see if the WoW nim client has features we can leverage
  - plan the work for the lua bot itself

- when work is done, use parallel independant agents to verify the work
  - Was any work done to coworld-vanilla-wow that was excessive and could live in wow-shadow-army instead? we want to rely on upstream as much as possible and reduce friction when pulling latest upstream
  - does the architecture of the bot make sense?
  - are changes supported by actual logs or facts from the game and not just assumed?