# =============================================================================
# § lib/diskmap.awk  ·  Squarified treemap renderer for the disk map
#
#   Reads the node list written by lib/actions/disk_map.sh and paints a
#   two-level treemap with ANSI colours: one tile per top-level folder, with
#   its biggest subfolders nested inside when the tile is large enough.
#   Tiles are separated by 1-cell gutters; "safe to remove" tiles get a green
#   diagonal hatch (category view) or a green fill (cleanup view).
#
#   Input (TSV, one node per line, already sorted largest-first per level):
#     kind  id  parent  kb  category  status  label  number
#       kind      1 = top-level tile, 2 = child of `parent`
#       category  code | docs | ai | sdk | pkg | other
#       status    safe | review | -
#       number    key shown on the tile (1-9) or -
#
#   Variables (-v): W H     map size in cells
#                   mode    truecolor | 256 | plain
#                   view    category | cleanup
#
#   Plain mode (no colour) prints a ranked list with ASCII bars instead.
#   Plain POSIX awk only - runs on the awk that ships with macOS.
# =============================================================================
BEGIN {
    FS = "\t"
    ESC = sprintf("%c", 27)

    # ── palette: tile fill (level 1 / level 2) and text colour per key ──────
    #    truecolor values are "r;g;b", 256-colour values are xterm indices.
    pal("code",   "224;224;250", "205;204;246", "55;48;140",   189, 147, 54)
    pal("docs",   "253;232;216", "250;212;186", "140;60;15",   223, 216, 94)
    pal("ai",     "251;222;233", "246;198;218", "140;25;75",   225, 218, 89)
    pal("sdk",    "214;236;243", "190;223;236", "15;85;105",   195, 152, 23)
    pal("pkg",    "220;231;252", "196;214;250", "30;60;150",   153, 111, 18)
    pal("other",  "234;234;237", "216;216;222", "70;70;80",    254, 251, 238)
    pal("safe",   "214;240;218", "186;228;193", "25;100;40",   194, 151, 22)
    pal("review", "253;230;205", "250;210;172", "150;75;10",   223, 215, 94)
    pal("keep",   "234;234;237", "216;216;222", "70;70;80",    254, 251, 238)
    HATCH_T = "60;150;80"; HATCH_8 = 28

    NAME["docs"]  = "Documents & media";  NAME["other"] = "Dev tools & other"
    NAME["code"]  = "Code projects";      NAME["sdk"]   = "iOS & Android SDKs"
    NAME["ai"]    = "AI models";          NAME["pkg"]   = "Package caches"
    ORDER = "docs other code sdk ai pkg"
}

function pal(k, t1, t2, tf, c1, c2, cf) {
    T1[k] = t1; T2[k] = t2; TF[k] = tf; E1[k] = c1; E2[k] = c2; EF[k] = cf
}
function bgc(k, lvl) {
    if (mode == "truecolor") return "48;2;" (lvl == 1 ? T1[k] : T2[k])
    return "48;5;" (lvl == 1 ? E1[k] : E2[k])
}
function fgc(k) { return mode == "truecolor" ? "38;2;" TF[k] : "38;5;" EF[k] }
function hatchc() { return mode == "truecolor" ? "38;2;" HATCH_T : "38;5;" HATCH_8 }
function swatch(k) { return mode == "truecolor" ? "38;2;" T2[k] : "38;5;" E2[k] }

function fmt(kb) {
    if (kb >= 104857600) return sprintf("%.0f GB", kb / 1048576)
    if (kb >= 1048576)   return sprintf("%.1f GB", kb / 1048576)
    if (kb >= 1024)      return sprintf("%.0f MB", kb / 1024)
    return sprintf("%d KB", kb)
}
function max(a, b) { return a > b ? a : b }
function min(a, b) { return a < b ? a : b }
function rnd(v) { return int(v + 0.5) }

# palette key + hatch flag for a node, depending on the view
function key_of(id) {
    if (view == "cleanup") return ST[id] == "safe" ? "safe" : (ST[id] == "review" ? "review" : "keep")
    return CAT[id]
}

{
    id = $2
    KIND[id] = $1; PAR[id] = $3; SZ[id] = $4 + 0; CAT[id] = $5
    ST[id] = ($6 == "-" ? "" : $6); LBL[id] = $7; NUM[id] = ($8 == "-" ? "" : $8)
    if ($1 == 1) TOP[++NTOP] = id
    else         KID[$3, ++NKID[$3]] = id
    if (CAT[id] != "") SEEN[CAT[id]] = 1
}

# =============================================================================
# § squarify  (Bruls, Huizing & van Wijk) over L[1..n], rect x y w h
#
#   Works in "visual" units where one cell row counts as 2 (terminal cells are
#   about twice as tall as wide), so tiles come out roughly square on screen.
#   Writes RX RY RW RH for every id.
# =============================================================================
function worst(s, mn, mx, sh,   s2, w2) {
    s2 = s * s; w2 = sh * sh
    return max(w2 * mx / s2, s2 / (w2 * mn))
}
function squarify(L, n, x, y, w, h,   st, en, k, rem, scale, sh, rs, rmin, rmax, cur, a, nrs, nmin, nmax, nw, t, off) {
    st = 1
    while (st <= n) {
        if (w <= 0 || h <= 0) {
            for (k = st; k <= n; k++) { RX[L[k]] = x; RY[L[k]] = y; RW[L[k]] = 0; RH[L[k]] = 0 }
            return
        }
        rem = 0
        for (k = st; k <= n; k++) rem += SZ[L[k]]
        if (rem <= 0) return
        scale = (w * h) / rem
        sh = min(w, h)
        rs = 0; rmin = 1e300; rmax = 0; cur = 1e300; en = st
        while (en <= n) {
            a = SZ[L[en]] * scale
            nrs = rs + a; nmin = min(rmin, a); nmax = max(rmax, a)
            nw = worst(nrs, nmin, nmax, sh)
            if (en > st && nw > cur) break
            rs = nrs; rmin = nmin; rmax = nmax; cur = nw; en++
        }
        if (w >= h) {                       # lay the row as a column on the left
            t = rs / h; off = y
            for (k = st; k < en; k++) {
                a = SZ[L[k]] * scale
                RX[L[k]] = x; RY[L[k]] = off; RW[L[k]] = t; RH[L[k]] = a / t; off += a / t
            }
            x += t; w -= t
        } else {                            # lay the row along the top
            t = rs / w; off = x
            for (k = st; k < en; k++) {
                a = SZ[L[k]] * scale
                RX[L[k]] = off; RY[L[k]] = y; RW[L[k]] = a / t; RH[L[k]] = t; off += a / t
            }
            y += t; h -= t
        }
        st = en
    }
}

# ── cell canvas ───────────────────────────────────────────────────────────────
function fill(x0, y0, x1, y1, k, lvl, hatch,   x, y) {
    for (y = y0; y < y1; y++) for (x = x0; x < x1; x++) {
        CB[y, x] = bgc(k, lvl); CD[y, x] = 0
        if (hatch && (x + y) % 3 == 0) { CH[y, x] = "╱"; CF[y, x] = hatchc() }
        else                           { CH[y, x] = " "; CF[y, x] = "" }
    }
}
function text(x, y, xmax, s, k, bold,   i, n) {
    n = length(s)
    if (x + n > xmax) {
        if (xmax - x < 2) return
        s = substr(s, 1, xmax - x - 1); n = length(s)
        CH[y, x + n] = "~"; CF[y, x + n] = fgc(k); CD[y, x + n] = bold
    }
    for (i = 1; i <= n; i++) { CH[y, x + i - 1] = substr(s, i, 1); CF[y, x + i - 1] = fgc(k); CD[y, x + i - 1] = bold }
}

# A tile without nested children: name on the first row, size on the last.
# Rect is in cells, exclusive; the last column and row are left as gutter.
function leaf(id, x0, y0, x1, y1, lvl,   k, w, h, nm, sz, tx) {
    x1--; y1--
    w = x1 - x0; h = y1 - y0
    if (w < 1 || h < 1) return
    k = key_of(id)
    fill(x0, y0, x1, y1, k, lvl, view == "category" && ST[id] == "safe")
    nm = (NUM[id] != "" ? NUM[id] " " : "") LBL[id]; sz = fmt(SZ[id])
    tx = (w >= 6) ? x0 + 1 : x0
    if (h >= 2) {
        text(tx, y0, x1, nm, k, lvl == 1)
        if (length(sz) <= x1 - tx) text(tx, y1 - 1, x1, sz, k, 1)
    } else if (length(nm) + length(sz) + 1 <= x1 - tx) {
        text(tx, y0, x1, nm " " sz, k, lvl == 1)
    } else {
        text(tx, y0, x1, nm, k, lvl == 1)
    }
}

# A top-level tile: header row with name + size, children nested below.
function parent(id, x0, y0, x1, y1,   k, w, h, i, n, L, ax0, ay0, ax1, ay1, c, sz, nm) {
    n = NKID[id] + 0
    w = x1 - 1 - x0; h = y1 - 1 - y0
    if (n == 0 || w < 12 || h < 5) { leaf(id, x0, y0, x1, y1, 1); return }
    k = key_of(id)
    fill(x0, y0, x1 - 1, y1 - 1, k, 1, 0)
    nm = (NUM[id] != "" ? NUM[id] " " : "") LBL[id]; sz = fmt(SZ[id])
    text(x0 + 1, y0, x1 - 3 - length(sz), nm, k, 1)
    text(x1 - 2 - length(sz), y0, x1 - 1, sz, k, 0)

    # children fill the area below the header, 1 cell in from the left edge;
    # each child's own gutter supplies the right and bottom margins.
    ax0 = x0 + 1; ay0 = y0 + 1; ax1 = x1 - 1; ay1 = y1 - 1
    for (i = 1; i <= n; i++) L[i] = KID[id, i]
    squarify(L, n, ax0, ay0 * 2, ax1 - ax0, (ay1 - ay0) * 2)
    for (i = 1; i <= n; i++) {
        c = L[i]
        leaf(c, rnd(RX[c]), rnd(RY[c] / 2), rnd(RX[c] + RW[c]), rnd((RY[c] + RH[c]) / 2), 2)
    }
}

function legend(   out, n, i, k, keys) {
    out = "  "
    if (view == "cleanup") {
        out = out ESC "[" swatch("safe") "m■" ESC "[0m Safe to remove   "
        out = out ESC "[" swatch("review") "m■" ESC "[0m Review first   "
        out = out ESC "[" swatch("keep") "m■" ESC "[0m Keep"
    } else {
        n = split(ORDER, keys, " ")
        for (i = 1; i <= n; i++) {
            k = keys[i]
            if (!(k in SEEN)) continue
            out = out ESC "[" swatch(k) "m■" ESC "[0m " NAME[k] "   "
        }
        out = out ESC "[" hatchc() "m╱╱" ESC "[0m safe to remove"
    }
    print out
}

function plain(   i, id, bar, j, n, tot, cats) {
    tot = 0
    for (i = 1; i <= NTOP; i++) tot += SZ[TOP[i]]
    for (i = 1; i <= NTOP; i++) {
        id = TOP[i]
        n = tot > 0 ? int(SZ[id] * 24 / tot + 0.5) : 0
        bar = ""
        for (j = 0; j < 24; j++) bar = bar (j < n ? "#" : ".")
        printf "  %2s %-30s %8s  [%s]  %s%s\n", NUM[id], substr(LBL[id], 1, 30), fmt(SZ[id]), bar, \
            NAME[CAT[id]], (ST[id] == "" ? "" : "  (" ST[id] ")")
    }
}

END {
    if (NTOP == 0) { print "  (nothing to show - folder is empty or unreadable)"; exit }
    if (mode == "plain") { plain(); exit }

    for (y = 0; y < H; y++) for (x = 0; x < W; x++) { CH[y, x] = " "; CB[y, x] = ""; CF[y, x] = ""; CD[y, x] = 0 }

    for (i = 1; i <= NTOP; i++) L0[i] = TOP[i]
    squarify(L0, NTOP, 0, 0, W, H * 2)
    for (i = 1; i <= NTOP; i++) {
        id = TOP[i]
        parent(id, rnd(RX[id]), rnd(RY[id] / 2), rnd(RX[id] + RW[id]), rnd((RY[id] + RH[id]) / 2))
    }

    # emit rows, switching SGR state only when a cell's style changes
    for (y = 0; y < H; y++) {
        line = "  "; prev = "-"
        for (x = 0; x < W; x++) {
            st = CB[y, x] "|" CF[y, x] "|" CD[y, x]
            if (st != prev) {
                sgr = "0"
                if (CB[y, x] != "") sgr = sgr ";" CB[y, x]
                if (CF[y, x] != "") sgr = sgr ";" CF[y, x]
                if (CD[y, x])       sgr = sgr ";1"
                line = line ESC "[" sgr "m"; prev = st
            }
            line = line CH[y, x]
        }
        print line ESC "[0m"
    }
    print ""
    legend()
}
