// json2dir: create the directory tree a JSON document describes, in the current directory.
// Implements RFC J2D-1 (https://github.com/kitsunoff/awesome-json2dir/blob/main/spec/rfc-json2dir.md).
// Vala with GLib and the posix bindings only; the JSON parser is hand-written.

errordomain J2DError { FAIL }

enum Kind { OBJECT, STRING, ARRAY }

class Node {
    public Kind kind;
    public uint8[] bytes;                         // STRING: exact UTF-8 bytes (may contain NUL)
    public GenericArray<Node> items;              // ARRAY
    public HashTable<string, Node> members;       // OBJECT (duplicate names: last one wins)

    public Node (Kind kind) {
        this.kind = kind;
        bytes = new uint8[0];
        items = new GenericArray<Node> ();
        members = new HashTable<string, Node> (str_hash, str_equal);
    }
}

// ---------- §3: strict JSON parser over raw bytes ----------

class Parser {
    uint8[] buf;
    int pos = 0;

    public Parser (uint8[] input) { buf = input; }

    J2DError err (string what) {
        return new J2DError.FAIL ("input is not valid JSON: %s at byte %d", what, pos);
    }

    int peek () { return pos < buf.length ? buf[pos] : -1; }

    void ws () {
        while (pos < buf.length && (buf[pos] == ' ' || buf[pos] == '\t' || buf[pos] == '\n' || buf[pos] == '\r'))
            pos++;
    }

    public Node parse_document () throws J2DError {
        // A leading BOM is ignored, as §3 allows.
        if (buf.length >= 3 && buf[0] == 0xEF && buf[1] == 0xBB && buf[2] == 0xBF) pos = 3;
        ws ();
        var v = value (0);
        ws ();
        if (pos != buf.length) throw err ("trailing data");
        return v;
    }

    Node value (int depth) throws J2DError {
        if (depth > 1000) throw err ("nesting too deep");
        int c = peek ();
        if (c == '{') return object (depth);
        if (c == '[') return array (depth);
        if (c == '"') {
            var n = new Node (Kind.STRING);
            n.bytes = str ();
            return n;
        }
        if (c == -1) throw err ("unexpected end of input");
        if (c == '-' || (c >= '0' && c <= '9') || c == 't' || c == 'f' || c == 'n')
            throw new J2DError.FAIL ("numbers, true, false and null are not allowed (byte %d)", pos);
        throw err ("unexpected character");
    }

    Node object (int depth) throws J2DError {
        var n = new Node (Kind.OBJECT);
        pos++;
        ws ();
        if (peek () == '}') { pos++; return n; }
        while (true) {
            ws ();
            if (peek () != '"') throw err ("expected member name");
            uint8[] nb = str ();
            foreach (uint8 b in nb)
                if (b == 0) throw new J2DError.FAIL ("invalid name: contains NUL");
            string name = bytes_to_string (nb);
            ws ();
            if (peek () != ':') throw err ("expected ':'");
            pos++;
            ws ();
            n.members.replace (name, value (depth + 1));
            ws ();
            int c = peek ();
            pos++;
            if (c == '}') return n;
            if (c != ',') { pos--; throw err ("expected ',' or '}'"); }
        }
    }

    Node array (int depth) throws J2DError {
        var n = new Node (Kind.ARRAY);
        pos++;
        ws ();
        if (peek () == ']') { pos++; return n; }
        while (true) {
            ws ();
            n.items.add (value (depth + 1));
            ws ();
            int c = peek ();
            pos++;
            if (c == ']') return n;
            if (c != ',') { pos--; throw err ("expected ',' or ']'"); }
        }
    }

    int hex4 () throws J2DError {
        if (pos + 4 > buf.length) throw err ("bad \\u escape");
        int v = 0;
        for (int i = 0; i < 4; i++) {
            int c = buf[pos++];
            int d;
            if (c >= '0' && c <= '9') d = c - '0';
            else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
            else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
            else throw err ("bad \\u escape");
            v = v * 16 + d;
        }
        return v;
    }

    static void put_utf8 (ByteArray acc, int cp) {
        uint8[] b;
        if (cp < 0x80) b = { (uint8) cp };
        else if (cp < 0x800) b = { (uint8) (0xC0 | (cp >> 6)), (uint8) (0x80 | (cp & 0x3F)) };
        else if (cp < 0x10000) b = { (uint8) (0xE0 | (cp >> 12)), (uint8) (0x80 | ((cp >> 6) & 0x3F)), (uint8) (0x80 | (cp & 0x3F)) };
        else b = { (uint8) (0xF0 | (cp >> 18)), (uint8) (0x80 | ((cp >> 12) & 0x3F)), (uint8) (0x80 | ((cp >> 6) & 0x3F)), (uint8) (0x80 | (cp & 0x3F)) };
        acc.append (b);
    }

    // Parses a string token; checks raw UTF-8 strictly and decodes escapes.
    uint8[] str () throws J2DError {
        var acc = new ByteArray ();
        pos++;
        while (true) {
            if (pos >= buf.length) throw err ("unterminated string");
            int c = buf[pos];
            if (c == '"') { pos++; break; }
            if (c < 0x20) throw err ("control character in string");
            if (c == '\\') {
                pos++;
                if (pos >= buf.length) throw err ("unterminated string");
                int e = buf[pos++];
                switch (e) {
                case '"': acc.append ({ '"' }); break;
                case '\\': acc.append ({ '\\' }); break;
                case '/': acc.append ({ '/' }); break;
                case 'b': acc.append ({ 8 }); break;
                case 'f': acc.append ({ 12 }); break;
                case 'n': acc.append ({ '\n' }); break;
                case 'r': acc.append ({ '\r' }); break;
                case 't': acc.append ({ '\t' }); break;
                case 'u':
                    int cp = hex4 ();
                    if (cp >= 0xD800 && cp <= 0xDBFF) {
                        if (pos + 1 < buf.length && buf[pos] == '\\' && buf[pos + 1] == 'u') {
                            pos += 2;
                            int lo = hex4 ();
                            if (lo < 0xDC00 || lo > 0xDFFF)
                                throw new J2DError.FAIL ("string contains an unpaired surrogate");
                            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                        } else {
                            throw new J2DError.FAIL ("string contains an unpaired surrogate");
                        }
                    } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
                        throw new J2DError.FAIL ("string contains an unpaired surrogate");
                    }
                    put_utf8 (acc, cp);
                    break;
                default:
                    throw err ("bad escape");
                }
                continue;
            }
            if (c < 0x80) { acc.append ({ (uint8) c }); pos++; continue; }
            // Multi-byte UTF-8 sequence: reject overlongs, surrogates and > U+10FFFF.
            int len; int min; int cp;
            if (c >= 0xC2 && c <= 0xDF) { len = 2; min = 0x80; cp = c & 0x1F; }
            else if (c >= 0xE0 && c <= 0xEF) { len = 3; min = 0x800; cp = c & 0x0F; }
            else if (c >= 0xF0 && c <= 0xF4) { len = 4; min = 0x10000; cp = c & 0x07; }
            else throw new J2DError.FAIL ("input is not valid UTF-8");
            if (pos + len > buf.length) throw new J2DError.FAIL ("input is not valid UTF-8");
            for (int i = 1; i < len; i++) {
                int cc = buf[pos + i];
                if ((cc & 0xC0) != 0x80) throw new J2DError.FAIL ("input is not valid UTF-8");
                cp = (cp << 6) | (cc & 0x3F);
            }
            if (cp < min || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF))
                throw new J2DError.FAIL ("input is not valid UTF-8");
            acc.append (buf[pos:pos + len]);
            pos += len;
        }
        return acc.data;
    }
}

string bytes_to_string (uint8[] b) {
    // Caller guarantees no NUL bytes.
    var copy = new uint8[b.length + 1];
    Memory.copy (copy, b, b.length);
    copy[b.length] = 0;
    return (string) copy;
}

bool bytes_eq (uint8[] b, string s) {
    if (b.length != s.length) return false;
    for (int i = 0; i < b.length; i++)
        if (b[i] != s.data[i]) return false;
    return true;
}

// ---------- §4: validate the whole document before writing ----------

void validate (Node n, string where) throws J2DError {
    switch (n.kind) {
    case Kind.STRING:
        return;
    case Kind.ARRAY:
        if (n.items.length != 2 || n.items[0].kind != Kind.STRING || n.items[1].kind != Kind.STRING)
            throw new J2DError.FAIL ("%s: an array must be [\"link\", target] or [\"script\", content]", where);
        bool link = bytes_eq (n.items[0].bytes, "link");
        if (!link && !bytes_eq (n.items[0].bytes, "script"))
            throw new J2DError.FAIL ("%s: unknown array kind", where);
        if (link) {
            foreach (uint8 b in n.items[1].bytes)
                if (b == 0) throw new J2DError.FAIL ("%s: a link target cannot contain NUL", where);
        }
        return;
    case Kind.OBJECT:
        foreach (string name in n.members.get_keys ()) {
            string child = where == "." ? name : where + "/" + name;
            if (name == "" || name == "." || name == ".." || name.contains ("/"))
                throw new J2DError.FAIL ("%s: invalid name", child);
            validate (n.members[name], child);
        }
        return;
    }
}

// ---------- §5: write the tree ----------

J2DError sys (string what, string path) {
    return new J2DError.FAIL ("%s: %s: %s", path, what, Posix.strerror (Posix.errno));
}

void write_file (string path, uint8[] content, bool executable) throws J2DError {
    // O_EXCL | O_NOFOLLOW: never writes through an entry that appeared after it was removed.
    int fd = Posix.open (path, Posix.O_WRONLY | Posix.O_CREAT | Posix.O_EXCL | Posix.O_NOFOLLOW, 0666);
    if (fd < 0) throw sys ("cannot create file", path);
    int off = 0;
    while (off < content.length) {
        ssize_t w = Posix.write (fd, &content[off], content.length - off);
        if (w < 0) {
            if (Posix.errno == Posix.EINTR) continue;
            Posix.close (fd);
            throw sys ("cannot write", path);
        }
        off += (int) w;
    }
    if (executable) {
        Posix.Stat st;
        if (Posix.fstat (fd, out st) != 0 || Posix.fchmod (fd, (st.st_mode & 07777) | 0111) != 0) {
            Posix.close (fd);
            throw sys ("cannot chmod", path);
        }
    }
    Posix.close (fd);
}

void apply (string dir, Node tree) throws J2DError {
    var names = tree.members.get_keys ();
    names.sort (strcmp);   // ascending UTF-8 byte order
    foreach (unowned string name in names) {
        string path = dir == "." ? name : dir + "/" + name;
        Node v = tree.members[name];
        Posix.Stat st;
        bool exists = Posix.lstat (path, out st) == 0;
        if (!exists && Posix.errno != Posix.ENOENT) throw sys ("cannot stat", path);
        bool is_dir = exists && Posix.S_ISDIR (st.st_mode);
        if (v.kind == Kind.OBJECT) {
            if (!is_dir) {
                if (exists && Posix.unlink (path) != 0) throw sys ("cannot remove", path);
                if (Posix.mkdir (path, 0777) != 0) throw sys ("cannot create directory", path);
            }
            apply (path, v);
            continue;
        }
        if (is_dir) throw new J2DError.FAIL ("%s: a directory is in the way", path);
        if (exists && Posix.unlink (path) != 0) throw sys ("cannot remove", path);
        if (v.kind == Kind.STRING) {
            write_file (path, v.bytes, false);
        } else if (bytes_eq (v.items[0].bytes, "link")) {
            if (Posix.symlink (bytes_to_string (v.items[1].bytes), path) != 0) throw sys ("cannot create symlink", path);
        } else {
            write_file (path, v.items[1].bytes, true);
        }
    }
}

uint8[] read_stdin () throws J2DError {
    var all = new ByteArray ();
    var chunk = new uint8[65536];
    while (true) {
        ssize_t r = Posix.read (0, chunk, chunk.length);
        if (r < 0) {
            if (Posix.errno == Posix.EINTR) continue;
            throw new J2DError.FAIL ("cannot read standard input: %s", Posix.strerror (Posix.errno));
        }
        if (r == 0) break;
        all.append (chunk[0:r]);
    }
    return all.data;
}

int main (string[] args) {
    if (args.length > 1) {
        stderr.printf ("usage: json2dir < document.json\n");
        return 2;
    }
    try {
        var doc = new Parser (read_stdin ()).parse_document ();
        if (doc.kind != Kind.OBJECT) throw new J2DError.FAIL ("the root of the document must be an object");
        validate (doc, ".");
        apply (".", doc);
    } catch (J2DError e) {
        stderr.printf ("json2dir: %s\n", e.message);
        return 1;
    }
    return 0;
}
