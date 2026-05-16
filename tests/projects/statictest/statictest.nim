import std/strtabs

static:
  let t = newStringTable(modeStyleInsensitive)
  t["alpha"] = "1"
  t["beta"] = "2"
  doAssert t["alpha"] == "1"
  doAssert t["beta"] == "2"

echo "hello"
