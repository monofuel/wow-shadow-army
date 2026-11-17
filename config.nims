import std/[os, strutils]

# Link the package paths Nimby generated for the wow-coworld global profile
# (`nimby sync -g` of this repo's lock and the client fork's lock). Reading the
# generated config keeps machine paths out of the repository and follows an
# explicit NIMBY_HOME.
let
  nimbyHome = getEnv("NIMBY_HOME", getHomeDir() / ".nimby" / "profiles" / "wow-coworld")
  profileConfig = nimbyHome / "nim.cfg"
if fileExists(profileConfig):
  for line in readFile(profileConfig).splitLines():
    if line.startsWith("--path:\"") and line.endsWith("\""):
      switch("path", line["--path:\"".len ..< line.high])
else:
  echo "warning: missing Nimby profile config " & profileConfig &
    "; see the dependency section of playbooks/pull-upstream.md"
