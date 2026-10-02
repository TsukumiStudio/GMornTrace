#!/bin/sh
# Stage a disposable project; the addon root must not contain project.godot.
# Process lifecycle/error/timeout/userdata isolation belongs to GMornTestRunner.
set -eu
trace_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
trace_engine=${GODOT_BIN:-$(command -v godot)}
trace_scratch=$(mktemp -d "${TMPDIR:-/tmp}/gmorntrace-project.XXXXXX")
trap 'rm -rf -- "$trace_scratch"' EXIT HUP INT TERM
cp "$trace_root/gmorn_trace.gd" "$trace_scratch/"
cp -R "$trace_root/examples" "$trace_root/tests" "$trace_scratch/"
cat > "$trace_scratch/project.godot" <<'PROJECT'
config_version=5
[application]
config/name="GMornTrace Synthetic Tests"
run/main_scene="res://boot.tscn"
[rendering]
renderer/rendering_method="gl_compatibility"
[audio]
driver/driver="Dummy"
PROJECT
cat > "$trace_scratch/boot.tscn" <<'SCENE'
[gd_scene format=3]
[node name="SyntheticBoot" type="Node"]
SCENE
set +e
GMORN_TRACE_ENGINE_BIN="$trace_engine" GODOT_BIN="$trace_root/tools/silent_godot.sh" \
 GMORN_TEST_PROJECT="$trace_scratch" GMORN_TEST_JOBS=1 GMORN_TEST_TIMEOUT=30 \
 "$trace_root/tools/gmorn_test_runner/run_tests.sh" headless
trace_result=$?
set -e
if [ -n "${GMORN_TRACE_EVIDENCE_DIR:-}" ]; then
 mkdir -p "$GMORN_TRACE_EVIDENCE_DIR"
 if [ -f "$trace_scratch/test-summary.json" ]; then
  cp "$trace_scratch/test-summary.json" "$GMORN_TRACE_EVIDENCE_DIR/test-summary.json"
 fi
fi
exit "$trace_result"
