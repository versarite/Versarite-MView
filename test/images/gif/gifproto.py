"""Prototype of the MView GIF decoder, same structure as the Pascal port
(uGifDecoder). Verified against Pillow."""
import numpy as np

MAX_CODES = 4096


def lzw_decode(data, mincs, npix):
    """Position-based LZW (GIF: LSB-first codes, no early change).
    Returns (bytearray of npix, produced)."""
    out = bytearray(npix)
    produced = 0
    if mincs < 1 or mincs > 11:
        return out, 0
    clear = 1 << mincs
    eoi = clear + 1
    pos = [0] * MAX_CODES
    ln = [0] * MAX_CODES
    codesize = mincs + 1
    nxt = eoi + 1
    have_prev = False
    prevpos = prevlen = 0
    bitbuf = 0
    bitcnt = 0
    i = 0
    n = len(data)
    while produced < npix:
        while bitcnt < codesize:
            if i >= n:
                return out, produced
            bitbuf |= data[i] << bitcnt
            bitcnt += 8
            i += 1
        code = bitbuf & ((1 << codesize) - 1)
        bitbuf >>= codesize
        bitcnt -= codesize

        if code == clear:
            codesize = mincs + 1
            nxt = eoi + 1
            have_prev = False
            continue
        if code == eoi:
            break

        curpos = produced
        if code < clear:
            out[produced] = code
            produced += 1
            curlen = 1
        elif code < nxt and code > eoi:
            src, l = pos[code], ln[code]
            if produced + l > npix:
                l = npix - produced
            out[produced:produced + l] = out[src:src + l]
            produced += l
            curlen = ln[code]
        elif code == nxt and have_prev:
            # KwKwK: previous string + its own first byte
            l = prevlen
            if produced + l > npix:
                l = npix - produced
            out[produced:produced + l] = out[prevpos:prevpos + l]
            produced += l
            if produced < npix:
                out[produced] = out[prevpos]
                produced += 1
            curlen = prevlen + 1
        else:
            break  # corrupt

        if have_prev and nxt < MAX_CODES:
            pos[nxt] = prevpos
            ln[nxt] = prevlen + 1
            nxt += 1
            if nxt == (1 << codesize) and codesize < 12:
                codesize += 1
        have_prev = True
        prevpos, prevlen = curpos, curlen
    return out, produced


class Frame:
    pass


def deinterlace(idx, w, h):
    out = bytearray(len(idx))
    r = 0
    for start, step in ((0, 8), (4, 8), (2, 4), (1, 2)):
        y = start
        while y < h:
            out[y * w:(y + 1) * w] = idx[r * w:(r + 1) * w]
            r += 1
            y += step
    return out


def read_palette(b, p, count):
    pal = np.zeros((256, 4), np.uint8)
    pal[:, 3] = 255
    for k in range(count):
        if p + 3 > len(b):
            break
        pal[k, 0:3] = list(b[p:p + 3])
        p += 3
    return pal, p


def parse(b, first_only=False):
    """Returns dict(width, height, loop, frames, more) or None if not a GIF."""
    if len(b) < 13 or b[:3] != b'GIF':
        return None
    W = b[6] | b[7] << 8
    H = b[8] | b[9] << 8
    packed = b[10]
    p = 13
    gct = None
    if packed & 0x80:
        gct, p = read_palette(b, p, 1 << ((packed & 7) + 1))
    loop = 0
    frames = []
    disposal = 0
    delay_cs = 0
    transparent = -1
    more = False
    while p < len(b):
        blk = b[p]
        p += 1
        if blk == 0x3B:
            break
        if blk == 0x21:
            if p >= len(b):
                break
            label = b[p]
            p += 1
            first = True
            while p < len(b):
                sz = b[p]
                p += 1
                if sz == 0:
                    break
                sub = b[p:p + sz]
                if label == 0xF9 and first and sz >= 4:
                    disposal = (sub[0] >> 2) & 7
                    delay_cs = sub[1] | sub[2] << 8
                    transparent = sub[3] if sub[0] & 1 else -1
                p += sz
                first = False
            continue
        if blk != 0x2C:
            break  # garbage: stop, keep what we have
        if first_only and frames:
            more = True
            break
        if p + 9 > len(b):
            break
        fx = b[p] | b[p + 1] << 8
        fy = b[p + 2] | b[p + 3] << 8
        fw = b[p + 4] | b[p + 5] << 8
        fh = b[p + 6] | b[p + 7] << 8
        fp = b[p + 8]
        p += 9
        pal = gct
        if fp & 0x80:
            pal, p = read_palette(b, p, 1 << ((fp & 7) + 1))
        if pal is None:
            pal = np.zeros((256, 4), np.uint8)
            pal[:, 3] = 255
            pal[1, 0:3] = 255
        if p >= len(b):
            break
        mincs = b[p]
        p += 1
        data = bytearray()
        ended_inside = True
        while p < len(b):
            sz = b[p]
            p += 1
            if sz == 0:
                ended_inside = False
                break
            data += b[p:p + sz]
            p += sz
        idx, produced = lzw_decode(data, mincs, fw * fh)
        if fp & 0x40 and fw > 0:
            idx = deinterlace(idx, fw, fh)
            # rows past 'produced' may be scattered; count rows decoded in
            # pass order -> mark the rest as not drawn by a mask
        f = Frame()
        f.x, f.y, f.w, f.h = fx, fy, fw, fh
        f.idx = idx
        f.produced = produced
        f.interlaced = bool(fp & 0x40)
        f.pal = pal.copy()
        f.transparent = transparent
        f.disposal = disposal
        f.delay = 100 if delay_cs <= 1 else delay_cs * 10
        if not (ended_inside and produced == 0 and fw * fh > 0):
            frames.append(f)
        disposal = 0
        delay_cs = 0
        transparent = -1
    # The canvas is the logical screen; frames are clipped to it (as the
    # GIF test suite expects). Only a 0 x 0 screen takes the first
    # frame's extent.
    if frames and (W == 0 or H == 0):
        W = max(1, frames[0].x + frames[0].w)
        H = max(1, frames[0].y + frames[0].h)
    return dict(width=W, height=H, loop=loop, frames=frames, more=more)


def drawn_mask(f):
    """Which pixels of the frame rect were decoded."""
    n = f.w * f.h
    m = np.zeros(n, bool)
    if not f.interlaced:
        m[:f.produced] = True
        return m.reshape(f.h, f.w) if n else m
    rows = f.produced // f.w if f.w else 0
    rest = f.produced % f.w if f.w else 0
    r = 0
    mm = np.zeros((f.h, f.w), bool)
    for start, step in ((0, 8), (4, 8), (2, 4), (1, 2)):
        y = start
        while y < f.h:
            if r < rows:
                mm[y, :] = True
            elif r == rows and rest:
                mm[y, :rest] = True
            r += 1
            y += step
    return mm


class Cursor:
    def __init__(self, gif):
        self.g = gif
        self.reset()

    def reset(self):
        self.canvas = np.zeros((self.g['height'], self.g['width'], 4), np.uint8)
        self.cur = -1
        self.saved = None

    def clip(self, f):
        W, H = self.g['width'], self.g['height']
        x0, y0 = min(f.x, W), min(f.y, H)
        x1, y1 = min(f.x + f.w, W), min(f.y + f.h, H)
        return x0, y0, x1, y1

    def frame(self, k):
        if k < self.cur:
            self.reset()
        while self.cur < k:
            if self.cur >= 0:
                pf = self.g['frames'][self.cur]
                x0, y0, x1, y1 = self.clip(pf)
                if pf.disposal == 2:
                    self.canvas[y0:y1, x0:x1] = 0
                elif pf.disposal == 3 and self.saved is not None:
                    self.canvas[y0:y1, x0:x1] = self.saved
            self.cur += 1
            f = self.g['frames'][self.cur]
            x0, y0, x1, y1 = self.clip(f)
            self.saved = self.canvas[y0:y1, x0:x1].copy() if f.disposal == 3 else None
            if x1 > x0 and y1 > y0:
                idx = np.frombuffer(bytes(f.idx), np.uint8).reshape(f.h, f.w)[:y1 - y0, :x1 - x0]
                m = drawn_mask(f)[:y1 - y0, :x1 - x0]
                if f.transparent >= 0:
                    m = m & (idx != f.transparent)
                region = self.canvas[y0:y1, x0:x1]
                region[m] = f.pal[idx[m]]
        return self.canvas.copy()
