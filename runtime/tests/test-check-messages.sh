#!/bin/bash
# check-runtime.sh's failure messages, with a fake runtime and a fake stepover command (no Wine): a
# Direct3D program that prints nothing, as on a runner whose virtual GPU hangs D3DMetal, is reported
# as such with its last output. Needs mingw-w64 (check-runtime.sh compiles the test programs).
command -v x86_64-w64-mingw32-gcc >/dev/null || { echo "skip test-check-messages (no mingw-w64)"; exit 0; }
tmp=$(mktemp -d)
for p in bin/wine bin/wineserver lib/wine/x86_64-unix/cxcompatdb.so lib/d3dmetal/external/D3DMetal.framework \
         lib/d3dmetal/wine/x86_64-windows lib/dxmt/x86_64-windows share/wine/mono share/wine/gecko; do
    mkdir -p "$tmp/cx99/$p"
done
echo "dxvk=none" > "$tmp/cx99/VERSION"
cat > "$tmp/stepover" <<'FAKE'
#!/bin/bash
case "$1" in
    create) mkdir -p "$STEPOVER_HOME/Bottles/$2/drive_c" ;;
    run) case "$3" in
             'C:\hello.exe') echo "stepover-compat: hello.exe: backend d3dmetal from /x"; echo stepover-check ;;
             'C:\d3d11.exe') echo "stepover-compat: d3d11.exe: backend d3dmetal from /x"; echo "msync: up and running." ;;
         esac ;;
esac
FAKE
chmod +x "$tmp/stepover"
out="$(STEPOVER_CLI="$tmp/stepover" runtime/check-runtime.sh "$tmp/cx99" --metal 2>&1)" && status=0 || status=$?
assert_eq "1" "$status" "a silent Direct3D program fails the check"
assert_eq "FAIL metal: d3d11.exe printed nothing (it crashed, or was still running after 300 s); last output: stepover-compat: d3d11.exe: backend d3dmetal from /x msync: up and running." \
    "$(printf '%s\n' "$out" | grep '^FAIL')" "and says so, with its last output"
rm -rf "$tmp"
