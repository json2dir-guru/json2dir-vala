# json2dir-vala

json2dir in Vala: creates the directory tree a JSON document describes, using only GLib and the posix bindings (hand-written JSON parser).

    valac --pkg posix -o json2dir json2dir.vala && ./json2dir < document.json
