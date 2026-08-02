#!/usr/bin/env python3
"""
Patches dwl.c to add image wallpaper support.
Run from inside the dwl source directory: python3 patch_wallpaper.py
"""

INCLUDE_ANCHOR = '#include "util.h"'
INCLUDE_BLOCK = '''#include "util.h"
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
#include <drm_fourcc.h>
#include <wlr/interfaces/wlr_buffer.h>'''

FUNCS_ANCHOR = "void\nsetup(void)\n{"
FUNCS_BLOCK = '''struct wallpaper_buffer {
	struct wlr_buffer base;
	unsigned char *data;
	uint32_t format;
	size_t stride;
};

static void
wallpaper_buffer_destroy(struct wlr_buffer *wlr_buffer)
{
	struct wallpaper_buffer *buffer = wl_container_of(wlr_buffer, buffer, base);
	stbi_image_free(buffer->data);
	free(buffer);
}

static bool
wallpaper_buffer_begin_data_ptr_access(struct wlr_buffer *wlr_buffer,
		uint32_t flags, void **data, uint32_t *format, size_t *stride)
{
	struct wallpaper_buffer *buffer = wl_container_of(wlr_buffer, buffer, base);
	*data = buffer->data;
	*format = buffer->format;
	*stride = buffer->stride;
	return true;
}

static void
wallpaper_buffer_end_data_ptr_access(struct wlr_buffer *wlr_buffer)
{
	/* no-op: pixel data stays resident for the buffer's lifetime */
}

static const struct wlr_buffer_impl wallpaper_buffer_impl = {
	.destroy = wallpaper_buffer_destroy,
	.begin_data_ptr_access = wallpaper_buffer_begin_data_ptr_access,
	.end_data_ptr_access = wallpaper_buffer_end_data_ptr_access,
};

static void
setwallpaper(const char *path)
{
	int w, h, channels;
	unsigned char *img = stbi_load(path, &w, &h, &channels, 4);
	if (!img) {
		fprintf(stderr, "wallpaper: failed to load %s\\n", path);
		return;
	}

	struct wallpaper_buffer *buffer = calloc(1, sizeof(*buffer));
	if (!buffer) {
		stbi_image_free(img);
		return;
	}

	wlr_buffer_init(&buffer->base, &wallpaper_buffer_impl, w, h);
	buffer->data = img;
	buffer->format = DRM_FORMAT_ABGR8888;
	buffer->stride = w * 4;

	struct wlr_scene_buffer *scene_buffer =
		wlr_scene_buffer_create(layers[LyrBg], &buffer->base);
	wlr_scene_node_set_position(&scene_buffer->node, 0, 0);
	wlr_buffer_drop(&buffer->base);
}

void
setup(void)
{'''

CALL_ANCHOR = "wlr_scene_node_place_below(&drag_icon->node, &layers[LyrBlock]->node);"
CALL_BLOCK = CALL_ANCHOR + "\n\tsetwallpaper(WALLPAPER_PATH);"

DECOR_ANCHOR = "xdg_decoration_mgr = wlr_xdg_decoration_manager_v1_create(dpy);"
DECOR_BLOCK = "xdg_decoration_mgr = wlr_xdg_decoration_manager_v1_create(dpy, 1);"

def patch(text, anchor, block, label):
	count = text.count(anchor)
	if count == 0:
		print(f"WARNING: anchor not found for [{label}] -- '{anchor[:50]}...' -- skipped")
		return text
	if count > 1:
		print(f"WARNING: anchor for [{label}] found {count} times -- only replacing first occurrence")
	return text.replace(anchor, block, 1)

with open("dwl.c", "r") as f:
	src = f.read()

if "setwallpaper" in src:
	print("ERROR: dwl.c already contains 'setwallpaper' -- run 'git checkout -- dwl.c' first to reset, then re-run this script.")
	raise SystemExit(1)

src = patch(src, INCLUDE_ANCHOR, INCLUDE_BLOCK, "includes")
src = patch(src, FUNCS_ANCHOR, FUNCS_BLOCK, "wallpaper functions")
src = patch(src, CALL_ANCHOR, CALL_BLOCK, "setwallpaper() call")
src = patch(src, DECOR_ANCHOR, DECOR_BLOCK, "decoration manager version arg")

with open("dwl.c", "w") as f:
	f.write(src)

print("Done. Run 'grep -n \"setwallpaper\\|WALLPAPER_PATH\" dwl.c' to verify placement.")
