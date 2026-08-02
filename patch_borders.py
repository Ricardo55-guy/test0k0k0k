#!/usr/bin/env python3
"""
Patches dwl.c + config.h for a nested triple-band border (maroon/black/maroon).
Run from inside the dwl source directory: python3 patch_borders.py
Each band's thickness = borderpx / 3, so set borderpx to a multiple of 3
(e.g. 12 for 4px per band) in config.h before building.
"""
import re

with open("dwl.c", "r") as f:
	dwl = f.read()

if "3 nested bands" in dwl:
	print("ERROR: dwl.c already patched -- run 'git checkout -- dwl.c' first.")
	raise SystemExit(1)

# --- 1. struct border[4] -> border[12] ---
struct_pat = re.compile(r'struct\s+wlr_scene_rect\s*\*border\[4\]\s*;[^\n]*')
struct_new = 'struct wlr_scene_rect *border[12]; /* 3 nested bands (outer,mid,inner) x (top,bottom,left,right) */'

if not struct_pat.search(dwl):
	print("ERROR: struct border[4] anchor not found -- aborting, no changes made.")
	raise SystemExit(1)
dwl = struct_pat.sub(struct_new, dwl, count=1)

# --- 2. creation loop: 4 rects -> 12 rects, banded colors ---
create_pat = re.compile(
	r'for\s*\(i\s*=\s*0;\s*i\s*<\s*4;\s*i\+\+\)\s*\{\s*'
	r'c->border\[i\]\s*=\s*wlr_scene_rect_create\(c->scene,\s*0,\s*0,\s*'
	r'c->isurgent\s*\?\s*urgentcolor\s*:\s*bordercolor\);\s*'
	r'c->border\[i\]->node\.data\s*=\s*c;\s*\}',
	re.MULTILINE
)
create_new = '''for (i = 0; i < 12; i++) {
\t\tconst float *bcol = (i / 4 == 1) ? bordercolor2
\t\t                  : (c->isurgent ? urgentcolor : bordercolor);
\t\tc->border[i] = wlr_scene_rect_create(c->scene, 0, 0, bcol);
\t\tc->border[i]->node.data = c;
\t}'''

if not create_pat.search(dwl):
	print("ERROR: border creation loop anchor not found -- aborting, no changes made.")
	raise SystemExit(1)
dwl = create_pat.sub(create_new, dwl, count=1)

# --- 3. resize/position block: 4 flat rects -> 12 nested rects ---
resize_pat = re.compile(
	r'wlr_scene_rect_set_size\(c->border\[0\],\s*c->geom\.width,\s*c->bw\);\s*'
	r'wlr_scene_rect_set_size\(c->border\[1\],\s*c->geom\.width,\s*c->bw\);\s*'
	r'wlr_scene_rect_set_size\(c->border\[2\],\s*c->bw,\s*c->geom\.height\s*-\s*2\s*\*\s*c->bw\);\s*'
	r'wlr_scene_rect_set_size\(c->border\[3\],\s*c->bw,\s*c->geom\.height\s*-\s*2\s*\*\s*c->bw\);\s*'
	r'wlr_scene_node_set_position\(&c->border\[1\]->node,\s*0,\s*c->geom\.height\s*-\s*c->bw\);\s*'
	r'wlr_scene_node_set_position\(&c->border\[2\]->node,\s*0,\s*c->bw\);\s*'
	r'wlr_scene_node_set_position\(&c->border\[3\]->node,\s*c->geom\.width\s*-\s*c->bw,\s*c->bw\);',
	re.MULTILINE
)
resize_new = '''{
\t\tunsigned int bw3 = c->bw / 3;
\t\tunsigned int k, base, offset, bwidth, bheight;
\t\tfor (k = 0; k < 3; k++) {
\t\t\toffset = k * bw3;
\t\t\tbwidth  = c->geom.width  - 2 * offset;
\t\t\tbheight = c->geom.height - 2 * offset;
\t\t\tbase = k * 4;
\t\t\twlr_scene_rect_set_size(c->border[base + 0], bwidth, bw3);
\t\t\twlr_scene_rect_set_size(c->border[base + 1], bwidth, bw3);
\t\t\twlr_scene_rect_set_size(c->border[base + 2], bw3, bheight - 2 * bw3);
\t\t\twlr_scene_rect_set_size(c->border[base + 3], bw3, bheight - 2 * bw3);
\t\t\twlr_scene_node_set_position(&c->border[base + 0]->node, offset, offset);
\t\t\twlr_scene_node_set_position(&c->border[base + 1]->node, offset, offset + bheight - bw3);
\t\t\twlr_scene_node_set_position(&c->border[base + 2]->node, offset, offset + bw3);
\t\t\twlr_scene_node_set_position(&c->border[base + 3]->node, offset + bwidth - bw3, offset + bw3);
\t\t}
\t}'''

if not resize_pat.search(dwl):
	print("ERROR: border resize/position anchor not found -- aborting, no changes made.")
	raise SystemExit(1)
dwl = resize_pat.sub(resize_new, dwl, count=1)

with open("dwl.c", "w") as f:
	f.write(dwl)
print("dwl.c patched successfully.")

# --- 4. config.h: add bordercolor2 (black), set borderpx to 12 ---
with open("config.h", "r") as f:
	cfg = f.read()

if "bordercolor2" in cfg:
	print("config.h already has bordercolor2 -- skipping config.h changes.")
else:
	cfg_pat = re.compile(r'(static\s+const\s+float\s+bordercolor\[\]\s*=\s*COLOR\([^\)]*\)\s*;)')
	if not cfg_pat.search(cfg):
		print("WARNING: bordercolor[] anchor not found in config.h -- add bordercolor2 manually:")
		print('  static const float bordercolor2[] = COLOR(0x000000ff); /* middle band, black */')
	else:
		cfg = cfg_pat.sub(r'\1\n' +
			'static const float bordercolor2[]      = COLOR(0x000000ff); /* middle band, black */',
			cfg, count=1)

	bw_pat = re.compile(r'static\s+const\s+unsigned\s+int\s+borderpx\s*=\s*\d+;')
	if bw_pat.search(cfg):
		cfg = bw_pat.sub('static const unsigned int borderpx         = 12;', cfg, count=1)
	else:
		print("WARNING: borderpx anchor not found -- set it to a multiple of 3 (e.g. 12) manually.")

	with open("config.h", "w") as f:
		f.write(cfg)
	print("config.h patched successfully.")

print("\nDone. Verify with:")
print('  grep -n "border\\[12\\]\\|bordercolor2\\|borderpx" dwl.c config.h')
