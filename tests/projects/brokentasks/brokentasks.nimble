# Package
#
# Deliberately broken: the task body calls an identifier that does not exist,
# so the real `nimble tasks` fails to evaluate this nimscript and exits
# non-zero. textensions.nim uses it to check that the server reports that
# failure as a JSON-RPC error instead of an empty task list.

version       = "0.1.0"
author        = "metacraft-labs"
description   = "Fixture whose nimscript does not compile"
license       = "MIT"

requires "nim >= 2.0.8"

task broken, "never evaluates":
  thisProcDoesNotExistInNimScript()
