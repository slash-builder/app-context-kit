#!/usr/bin/env python3
"""Writes spec/conformance/*.json. The expectations are spelled out from templates, not computed by
an implementation, so a Rust or Dart implementation that agrees has been checked against the prose spec."""
import json, pathlib
out = pathlib.Path(__file__).resolve().parent.parent / "spec" / "conformance"

def man(id="com.slashbuilder.demo.calc", **kw):
    m = {"id": id, "name": "Demo", "version": "0.1.0"}; m.update(kw); return m

def linux(id, h="/home/user"):
    return dict(data=f"{h}/.local/share/{id}", config=f"{h}/.config/{id}", state=f"{h}/.local/state/{id}",
                cache=f"{h}/.cache/{id}", runtime=f"{h}/.local/state/{id}/run")

def scratch(id, s):
    return {k: f"{s}/{id}/{k}" for k in ("data", "config", "state", "cache", "runtime")}

def case(name, manifest, platform, home, env, prefix=None, dirs=None, roster=None, scratch_=False, mode="real", error=None):
    c = {"name": name, "manifest": manifest, "platform": platform, "home": home, "env": env}
    if error: c["error"] = error
    else: c["expect"] = {"prefix": prefix, "dirs": dirs, "roster": roster, "scratch": scratch_, "mode": mode}
    return c

I = "com.slashbuilder.demo.calc"
cases = [
 case("linux-defaults", man(), "linux", "/home/user", {}, "CALC", linux(I), "/tmp/app-context-roster"),
 case("linux-xdg", man(), "linux", "/home/user",
      {"XDG_DATA_HOME":"/x/data","XDG_CONFIG_HOME":"/x/config","XDG_STATE_HOME":"/x/state","XDG_CACHE_HOME":"/x/cache","XDG_RUNTIME_DIR":"/run/user/1000"},
      "CALC", dict(data=f"/x/data/{I}", config=f"/x/config/{I}", state=f"/x/state/{I}", cache=f"/x/cache/{I}", runtime=f"/run/user/1000/{I}"),
      "/run/user/1000/app-context-roster"),
 case("linux-trailing-slashes", man(), "linux", "/home/user", {"XDG_DATA_HOME":"/x/data/","XDG_RUNTIME_DIR":"/run/user/1000/"},
      "CALC", dict(linux(I), data=f"/x/data/{I}", runtime=f"/run/user/1000/{I}"), "/run/user/1000/app-context-roster"),
 case("macos-defaults", man(), "macos", "/Users/user", {"TMPDIR":"/var/folders/ab/T/"}, "CALC",
      dict(data=f"/Users/user/Library/Application Support/{I}/data", config=f"/Users/user/Library/Preferences/{I}",
           state=f"/Users/user/Library/Application Support/{I}/state", cache=f"/Users/user/Library/Caches/{I}", runtime=f"/var/folders/ab/T/{I}"),
      "/var/folders/ab/T/app-context-roster"),
 case("macos-no-tmpdir", man(), "macos", "/Users/user", {}, "CALC",
      dict(data=f"/Users/user/Library/Application Support/{I}/data", config=f"/Users/user/Library/Preferences/{I}",
           state=f"/Users/user/Library/Application Support/{I}/state", cache=f"/Users/user/Library/Caches/{I}", runtime=f"/tmp/{I}"),
      "/tmp/app-context-roster"),
 case("windows-defaults", man(), "windows", "C:\\Users\\user",
      {"LOCALAPPDATA":"C:\\Users\\user\\AppData\\Local","APPDATA":"C:\\Users\\user\\AppData\\Roaming","TEMP":"C:\\Users\\user\\AppData\\Local\\Temp\\"}, "CALC",
      dict(data=f"C:\\Users\\user\\AppData\\Local\\{I}\\data", config=f"C:\\Users\\user\\AppData\\Roaming\\{I}",
           state=f"C:\\Users\\user\\AppData\\Local\\{I}\\state", cache=f"C:\\Users\\user\\AppData\\Local\\{I}\\cache",
           runtime=f"C:\\Users\\user\\AppData\\Local\\Temp\\{I}"), "C:\\Users\\user\\AppData\\Local\\Temp\\app-context-roster"),
 case("windows-missing-env", man(), "windows", "C:\\Users\\user", {}, error="missing-env"),
 case("per-dir-override", man("com.slashbuilder.demo.stopwatch"), "linux", "/home/user", {"STOPWATCH_DATA_DIR":"/override/data"}, "STOPWATCH",
      dict(linux("com.slashbuilder.demo.stopwatch"), data="/override/data"), "/tmp/app-context-roster"),
 case("scratch-on-macos", man(), "macos", "/Users/user", {"APP_CONTEXT_SCRATCH":"/tmp/scratch"}, "CALC", scratch(I, "/tmp/scratch"), "/tmp/scratch/roster", True),
 case("scratch-on-windows-needs-no-env", man(), "windows", "C:\\Users\\user", {"APP_CONTEXT_SCRATCH":"C:/s"}, "CALC", scratch(I, "C:/s"), "C:/s/roster", True),
 case("scratch-plus-override", man(), "linux", "/home/user", {"APP_CONTEXT_SCRATCH":"/tmp/s","CALC_CONFIG_DIR":"/etc/calc"}, "CALC",
      dict(scratch(I, "/tmp/s"), config="/etc/calc"), "/tmp/s/roster", True),
 case("roster-override-beats-scratch", man(), "linux", "/home/user", {"APP_CONTEXT_SCRATCH":"/tmp/s","APP_CONTEXT_ROSTER_DIR":"/shared/roster"}, "CALC",
      scratch(I, "/tmp/s"), "/shared/roster", True),
 case("prefix-from-manifest", man("com.slashbuilder.demo.minesweeper", envPrefix="MINES"), "linux", "/home/user",
      {"MINES_MODE":"mock","MINESWEEPER_MODE":"real"}, "MINES", linux("com.slashbuilder.demo.minesweeper"), "/tmp/app-context-roster", mode="mock"),
 case("mode-app-beats-global", man(), "linux", "/home/user", {"APP_CONTEXT_MODE":"mock","CALC_MODE":"real"}, "CALC", linux(I), "/tmp/app-context-roster", mode="real"),
 case("mode-global", man(), "linux", "/home/user", {"APP_CONTEXT_MODE":"mock"}, "CALC", linux(I), "/tmp/app-context-roster", mode="mock"),
 case("bad-mode", man(), "linux", "/home/user", {"CALC_MODE":"fake"}, error="bad-mode"),
 case("empty-means-unset", man(), "linux", "/home/user", {"CALC_MODE":"","XDG_DATA_HOME":"","CALC_DATA_DIR":"","APP_CONTEXT_SCRATCH":""}, "CALC", linux(I), "/tmp/app-context-roster"),
 case("runtime-follows-xdg-state-when-no-runtime-dir", man(), "linux", "/home/user", {"XDG_STATE_HOME":"/x/state"}, "CALC",
      dict(linux(I), state=f"/x/state/{I}", runtime=f"/x/state/{I}/run"), "/tmp/app-context-roster"),
 case("root-base-is-not-doubled", man(), "linux", "/home/user", {"XDG_DATA_HOME":"/"}, "CALC", dict(linux(I), data=f"/{I}"), "/tmp/app-context-roster"),
 case("linux-keeps-trailing-backslash", man(), "linux", "/home/user", {"XDG_DATA_HOME":"/x/data\\"}, "CALC", dict(linux(I), data=f"/x/data\\/{I}"), "/tmp/app-context-roster"),
 case("windows-trims-either-separator", man(), "windows", "C:\\Users\\user",
      {"LOCALAPPDATA":"C:\\L/","APPDATA":"C:\\A\\","TEMP":"C:\\T/"}, "CALC",
      dict(data=f"C:\\L\\{I}\\data", config=f"C:\\A\\{I}", state=f"C:\\L\\{I}\\state", cache=f"C:\\L\\{I}\\cache", runtime=f"C:\\T\\{I}"), "C:\\T\\app-context-roster"),
 case("override-is-verbatim", man(), "linux", "/home/user", {"CALC_DATA_DIR":"/o/data/"}, "CALC", dict(linux(I), data="/o/data/"), "/tmp/app-context-roster"),
 case("garbage-global-mode-ignored-when-app-mode-set", man(), "linux", "/home/user", {"CALC_MODE":"mock","APP_CONTEXT_MODE":"garbage"}, "CALC", linux(I), "/tmp/app-context-roster", mode="mock"),
 case("bad-mode-before-missing-env", man(), "windows", "C:\\Users\\user", {"CALC_MODE":"fake"}, error="bad-mode"),
 case("hyphen-in-id", man("com.slashbuilder.demo.render-queue"), "linux", "/home/user", {"RENDER_QUEUE_STATE_DIR":"/q/state"}, "RENDER_QUEUE",
      dict(linux("com.slashbuilder.demo.render-queue"), state="/q/state"), "/tmp/app-context-roster"),
]
(out / "context_cases.json").write_text(json.dumps(cases, indent=1) + "\n")

V = lambda **kw: man(**kw)
ok = lambda name, m, defaults=None: {"name": name, "manifest": m, "valid": True, "defaults": defaults}
bad = lambda name, m, code: {"name": name, "manifest": m, "valid": False, "error": code}
mc = [
 ok("minimal", man(), {"kits": [], "venueMode": "auto", "venueConsumer": "calc"}),
 ok("full", man("com.slashbuilder.demo.render-queue", kits=["venue", "storage"], envPrefix="RQ", venue={"mode": "on", "consumer": "rq-app"}),
    {"kits": ["venue", "storage"], "venueMode": "on", "venueConsumer": "rq-app"}),
 ok("venue-off", man(venue={"mode": "off"}), {"kits": [], "venueMode": "off", "venueConsumer": "calc"}),
 bad("not-an-object", [1, 2], "not-object"),
 bad("id-missing", {"name": "x", "version": "0.1.0"}, "bad-id"),
 bad("id-uppercase", man("Dev.Demo.Calc"), "bad-id"),
 bad("id-one-segment", man("calc"), "bad-id"),
 bad("id-leading-digit-segment", man("dev.1demo.calc"), "bad-id"),
 bad("id-underscore", man("com.slashbuilder.demo.my_app"), "bad-id"),
 bad("name-blank", man(name="   "), "bad-name"),
 bad("name-not-string", man(name=5), "bad-name"),
 bad("version-two-parts", man(version="0.1"), "bad-version"),
 bad("version-prerelease", man(version="0.1.0-beta"), "bad-version"),
 bad("kits-not-list", man(kits="venue"), "bad-kits"),
 bad("kit-uppercase", man(kits=["Venue"]), "bad-kits"),
 bad("kit-not-string", man(kits=[3]), "bad-kits"),
 bad("kit-duplicate", man(kits=["venue", "venue"]), "duplicate-kit"),
 bad("prefix-lowercase", man(envPrefix="calc"), "bad-prefix"),
 bad("venue-not-object", man(venue="auto"), "bad-venue"),
 bad("venue-mode-unknown", man(venue={"mode": "maybe"}), "bad-venue"),
 bad("venue-consumer-uppercase", man(venue={"consumer": "Calc"}), "bad-venue"),
 {"name": "source-not-json", "source": "{not json", "valid": False, "error": "not-json"},
 {"name": "source-array", "source": "[1, 2]", "valid": False, "error": "not-object"},
 {"name": "source-null", "source": "null", "valid": False, "error": "not-object"},
 {"name": "source-ok", "source": '{"id":"com.slashbuilder.demo.calc","name":"Demo","version":"0.1.0"}', "valid": True, "defaults": {"kits": [], "venueMode": "auto", "venueConsumer": "calc"}},
 bad("id-trailing-newline", man("com.slashbuilder.demo.calc\n"), "bad-id"),
 bad("version-trailing-newline", man(version="1.0.0\n"), "bad-version"),
 bad("name-only-ascii-whitespace", man(name="\t \r\n"), "bad-name"),
 ok("name-bom-counts-as-content", man(name="\ufeff"), {"kits": [], "venueMode": "auto", "venueConsumer": "calc"}),
 bad("name-null", man(name=None), "bad-name"),
 bad("kits-null", man(kits=None), "bad-kits"),
 bad("prefix-null", man(envPrefix=None), "bad-prefix"),
 bad("venue-null", man(venue=None), "bad-venue"),
 bad("bad-kit-beats-duplicate", man(kits=["venue", "venue", "Bad"]), "bad-kits"),
 bad("first-failure-wins", {"id": "BAD", "name": "", "version": "x"}, "bad-id"),
 bad("name-before-version", {"id": "com.slashbuilder.demo.calc", "name": "", "version": "x"}, "bad-name"),
]
(out / "manifest_cases.json").write_text(json.dumps(mc, indent=1) + "\n")
print(len(cases), "context cases,", len(mc), "manifest cases")

# --- snapshot_negative_cases.json (spec section 8): a snapshot the adopting side must refuse. ---
# The positive cases are NOT here: they are written by the Dart test dart/app_context_kit/test/snapshot_test.dart from real
# contexts (SNAPSHOT_FIXTURE_WRITE=1). Each negative case carries either `source` (text, to reach not-json) or `snapshot`,
# the error code, and for field errors the field. Only the first failure is reported, in the order of spec section 8.
import copy
good = {"schema": 1, "appId": "com.slashbuilder.demo.notes-rust", "instance": "0a1b2c3d", "mode": "real", "scratch": False,
        "dirs": {"data": "/a/data", "config": "/a/config", "state": "/a/state", "cache": "/a/cache", "runtime": "/a/runtime"},
        "roster": "/a/roster"}

def mut(path, value=None, drop=False):
    s = copy.deepcopy(good)
    t = s
    for k in path[:-1]: t = t[k]
    if drop: del t[path[-1]]
    else: t[path[-1]] = value
    return s

def neg(name, error, field=None, snapshot=None, source=None):
    c = {"name": name, "error": error}
    if field: c["field"] = field
    if source is not None: c["source"] = source
    else: c["snapshot"] = snapshot
    return c

neg_cases = [
 neg("not-json", "not-json", source="{nope"),
 neg("not-an-object", "not-object", snapshot=[1, 2]),
 neg("schema-missing", "missing-field", "schema", mut(["schema"], drop=True)),
 neg("schema-2", "unknown-schema", snapshot=mut(["schema"], 2)),
 neg("schema-0", "unknown-schema", snapshot=mut(["schema"], 0)),
 neg("schema-as-text", "unknown-schema", snapshot=mut(["schema"], "1")),
 neg("app-id-missing", "missing-field", "appId", mut(["appId"], drop=True)),
 neg("instance-missing", "missing-field", "instance", mut(["instance"], drop=True)),
 neg("dirs-missing", "missing-field", "dirs", mut(["dirs"], drop=True)),
 neg("dirs-data-missing", "missing-field", "dirs.data", mut(["dirs", "data"], drop=True)),
 neg("dirs-runtime-missing", "missing-field", "dirs.runtime", mut(["dirs", "runtime"], drop=True)),
 neg("roster-missing", "missing-field", "roster", mut(["roster"], drop=True)),
 neg("missing-beats-bad", "missing-field", "roster", dict(mut(["roster"], drop=True), mode="fake")),
 neg("unknown-top-level-field", "unknown-field", "token", dict(good, token="secret")),
 neg("unknown-dirs-field", "unknown-field", "dirs.logs", mut(["dirs", "logs"], "/a/logs")),
 neg("dirs-not-an-object", "bad-field", "dirs", mut(["dirs"], "/a")),
 neg("app-id-not-reverse-dns", "bad-field", "appId", mut(["appId"], "Notes")),
 neg("app-id-one-segment", "bad-field", "appId", mut(["appId"], "notes")),
 neg("instance-uppercase", "bad-field", "instance", mut(["instance"], "0A1B2C3D")),
 neg("instance-too-short", "bad-field", "instance", mut(["instance"], "0a1b2c")),
 neg("mode-unknown", "bad-field", "mode", mut(["mode"], "fake")),
 neg("scratch-not-a-bool", "bad-field", "scratch", mut(["scratch"], "yes")),
 neg("data-not-a-string", "bad-field", "dirs.data", mut(["dirs", "data"], 5)),
 neg("config-empty", "bad-field", "dirs.config", mut(["dirs", "config"], "")),
 neg("data-relative", "relative-path", "dirs.data", mut(["dirs", "data"], "data")),
 neg("config-dot-relative", "relative-path", "dirs.config", mut(["dirs", "config"], "./config")),
 neg("state-parent-relative", "relative-path", "dirs.state", mut(["dirs", "state"], "../state")),
 neg("cache-drive-relative", "relative-path", "dirs.cache", mut(["dirs", "cache"], "C:cache")),
 neg("runtime-bare-drive", "relative-path", "dirs.runtime", mut(["dirs", "runtime"], "C:")),
 neg("roster-relative", "relative-path", "roster", mut(["roster"], "roster")),
]
(out / "snapshot_negative_cases.json").write_text(json.dumps(neg_cases, indent=1) + "\n")
