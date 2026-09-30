/* Text rendering port for the Nest: rasterises UTF-8 text from a TrueType font
 * already on the device (e.g. /nestlabs/share/fonts/AkkuratNest-Bold.ttf), so no
 * font data ever ships with the SDK. Uses stb_truetype (public domain / MIT).
 *
 * Run as an Erlang port with {packet, 4}. All integers are big-endian.
 *   request: size_px:16 fg_rgb:24 bg_rgb:24 path_len:16 path text(utf8)
 *   reply:   0 width:16 height:16 pixels   (BGRX, text anti-aliased onto bg)
 *            1 message                     (error)
 * Font size follows the usual convention: size_px is the em size in pixels.
 */
#define STB_TRUETYPE_IMPLEMENTATION
#include "vendor/stb_truetype.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MAX_FONTS 4
#define MAX_TEXT 256
#define MAX_DIM 1024

struct font {
    char path[256];
    unsigned char *data;
    stbtt_fontinfo info;
};

static struct font fonts[MAX_FONTS];
static int font_count;

static int read_exact(void *buf, size_t n) {
    size_t got = 0;
    while (got < n) {
        ssize_t r = read(STDIN_FILENO, (char *)buf + got, n - got);
        if (r <= 0) return -1;
        got += (size_t)r;
    }
    return 0;
}

static int write_exact(const void *buf, size_t n) {
    size_t done = 0;
    while (done < n) {
        ssize_t w = write(STDOUT_FILENO, (const char *)buf + done, n - done);
        if (w <= 0) return -1;
        done += (size_t)w;
    }
    return 0;
}

static int reply(const unsigned char *body, uint32_t len) {
    unsigned char hdr[4] = {len >> 24, len >> 16, len >> 8, len};
    return write_exact(hdr, 4) || write_exact(body, len) ? -1 : 0;
}

static int reply_error(const char *msg) {
    unsigned char buf[128];
    size_t n = strlen(msg);
    if (n > sizeof(buf) - 1) n = sizeof(buf) - 1;
    buf[0] = 1;
    memcpy(buf + 1, msg, n);
    return reply(buf, (uint32_t)(n + 1));
}

static stbtt_fontinfo *load_font(const char *path) {
    for (int i = 0; i < font_count; i++)
        if (strcmp(fonts[i].path, path) == 0) return &fonts[i].info;
    if (font_count == MAX_FONTS) return NULL;

    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *data = malloc((size_t)size);
    if (!data || fread(data, 1, (size_t)size, f) != (size_t)size) {
        fclose(f);
        free(data);
        return NULL;
    }
    fclose(f);

    struct font *slot = &fonts[font_count];
    if (!stbtt_InitFont(&slot->info, data, stbtt_GetFontOffsetForIndex(data, 0))) {
        free(data);
        return NULL;
    }
    snprintf(slot->path, sizeof(slot->path), "%s", path);
    slot->data = data;
    font_count++;
    return &slot->info;
}

/* Returns the number of codepoints decoded; invalid bytes become U+FFFD. */
static int decode_utf8(const unsigned char *s, size_t n, int *out, int max) {
    int count = 0;
    size_t i = 0;
    while (i < n && count < max) {
        unsigned c = s[i];
        int cp, extra;
        if (c < 0x80) { cp = c; extra = 0; }
        else if ((c & 0xE0) == 0xC0) { cp = c & 0x1F; extra = 1; }
        else if ((c & 0xF0) == 0xE0) { cp = c & 0x0F; extra = 2; }
        else if ((c & 0xF8) == 0xF0) { cp = c & 0x07; extra = 3; }
        else { out[count++] = 0xFFFD; i++; continue; }
        if (i + (size_t)extra >= n) { out[count++] = 0xFFFD; break; }   /* truncated sequence */
        for (int k = 1; k <= extra; k++) cp = (cp << 6) | (s[i + k] & 0x3F);
        out[count++] = cp;
        i += (size_t)extra + 1;
    }
    return count;
}

static int handle(const unsigned char *req, uint32_t len) {
    if (len < 10) return reply_error("request too short");
    int size_px = req[0] << 8 | req[1];
    const unsigned char *fg = req + 2, *bg = req + 5;
    int path_len = req[8] << 8 | req[9];
    if (size_px < 4 || size_px > 400) return reply_error("bad size");
    if (10u + (unsigned)path_len > len || path_len >= 256) return reply_error("bad font path");

    char path[256];
    memcpy(path, req + 10, (size_t)path_len);
    path[path_len] = 0;
    stbtt_fontinfo *font = load_font(path);
    if (!font) return reply_error("cannot load font");

    int cps[MAX_TEXT];
    int n = decode_utf8(req + 10 + path_len, len - 10 - (uint32_t)path_len, cps, MAX_TEXT);

    float scale = stbtt_ScaleForMappingEmToPixels(font, (float)size_px);
    int ascent, descent, gap;
    stbtt_GetFontVMetrics(font, &ascent, &descent, &gap);
    int baseline = (int)ceilf(ascent * scale);
    int height = baseline + (int)ceilf(-descent * scale);

    float pen = 0;
    for (int i = 0; i < n; i++) {
        int adv, lsb;
        stbtt_GetCodepointHMetrics(font, cps[i], &adv, &lsb);
        pen += adv * scale;
        if (i + 1 < n) pen += scale * stbtt_GetCodepointKernAdvance(font, cps[i], cps[i + 1]);
    }
    int width = (int)ceilf(pen);
    if (width < 1) width = 1;
    if (width > MAX_DIM || height > MAX_DIM) return reply_error("text too large");

    unsigned char *cov = calloc((size_t)width * height, 1);
    if (!cov) return reply_error("out of memory");

    pen = 0;
    for (int i = 0; i < n; i++) {
        int adv, lsb, x0, y0, x1, y1;
        stbtt_GetCodepointHMetrics(font, cps[i], &adv, &lsb);
        float shift = pen - floorf(pen);
        stbtt_GetCodepointBitmapBoxSubpixel(font, cps[i], scale, scale, shift, 0, &x0, &y0, &x1, &y1);
        int gw = x1 - x0, gh = y1 - y0;
        if (gw > 0 && gh > 0) {
            unsigned char *g = calloc((size_t)gw * gh, 1);
            if (g) {
                stbtt_MakeCodepointBitmapSubpixel(font, g, gw, gh, gw, scale, scale, shift, 0, cps[i]);
                int ox = (int)floorf(pen) + x0, oy = baseline + y0;
                for (int y = 0; y < gh; y++) {
                    int ty = oy + y;
                    if (ty < 0 || ty >= height) continue;
                    for (int x = 0; x < gw; x++) {
                        int tx = ox + x;
                        if (tx < 0 || tx >= width) continue;
                        int v = cov[ty * width + tx] + g[y * gw + x];
                        cov[ty * width + tx] = v > 255 ? 255 : (unsigned char)v;
                    }
                }
                free(g);
            }
        }
        pen += adv * scale;
        if (i + 1 < n) pen += scale * stbtt_GetCodepointKernAdvance(font, cps[i], cps[i + 1]);
    }

    size_t pixels = (size_t)width * height;
    unsigned char *out = malloc(5 + pixels * 4);
    if (!out) { free(cov); return reply_error("out of memory"); }
    out[0] = 0;
    out[1] = width >> 8; out[2] = width;
    out[3] = height >> 8; out[4] = height;
    for (size_t p = 0; p < pixels; p++) {
        int a = cov[p];
        unsigned char *px = out + 5 + p * 4;
        px[0] = (unsigned char)(bg[2] + (fg[2] - bg[2]) * a / 255);
        px[1] = (unsigned char)(bg[1] + (fg[1] - bg[1]) * a / 255);
        px[2] = (unsigned char)(bg[0] + (fg[0] - bg[0]) * a / 255);
        px[3] = 0;
    }
    free(cov);
    int rc = reply(out, (uint32_t)(5 + pixels * 4));
    free(out);
    return rc;
}

int main(void) {
    for (;;) {
        unsigned char hdr[4];
        if (read_exact(hdr, 4)) return 0;
        uint32_t len = (uint32_t)hdr[0] << 24 | hdr[1] << 16 | hdr[2] << 8 | hdr[3];
        if (len > 65536) return 1;
        unsigned char *req = malloc(len ? len : 1);
        if (!req || read_exact(req, len)) return 0;
        int rc = handle(req, len);
        free(req);
        if (rc) return 0;
    }
}
