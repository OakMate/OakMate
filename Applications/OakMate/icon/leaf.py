#!/usr/bin/env python3
# Generates the layers of OakMate.icon: an upright oak leaf whose midrib
# continues below the blade as a text caret. Requires numpy.
#
#   python3 Applications/OakMate/icon/leaf.py Applications/OakMate/icon/OakMate.icon/Assets
#
# The leaf is a smooth union of ellipses (signed distance field). Its
# outline is traced with marching squares, simplified, and written as
# Catmull-Rom curves.
import math, sys
import numpy as np

SIZE = 1024
CX   = 512.0
TOP  = 135.0        # y of the leaf tip
LEN  = 590.0        # blade length

# Lobes: (position along the blade 0…1, distance from the midrib, semi-axes along/across, lean in degrees), relative to LEN
RIGHT = [ (0.20, 0.135, 0.065, 0.090, 35), (0.40, 0.185, 0.085, 0.115, 30), (0.61, 0.195, 0.088, 0.118, 25), (0.80, 0.150, 0.078, 0.100, 18) ]
LEFT  = [ (0.16, 0.125, 0.062, 0.085, 35), (0.35, 0.180, 0.082, 0.112, 30), (0.56, 0.200, 0.090, 0.120, 25), (0.76, 0.165, 0.080, 0.105, 18) ]
TIP   = (0.91, 0.0, 0.090, 0.085, 0)
BODY  = (0.50, 0.0, 0.48, 0.140, 0)   # the central part of the blade
BLEND = 0.045                         # smooth-union radius, rounds the sinuses

def ellipse_sdf(px, py, cx, cy, a, b, lean):
	# Approximate distance to an ellipse with semi-axes a (along the blade) and b (across), rotated by lean
	c, s = math.cos(math.radians(lean)), math.sin(math.radians(lean))
	dx, dy = px - cx, py - cy
	u =  dx * c + dy * s
	v = -dx * s + dy * c
	k = np.sqrt((u / b) ** 2 + (v / a) ** 2)
	return (k - 1) * min(a, b)

def smin(a, b, k):
	h = np.clip(0.5 + 0.5 * (b - a) / k, 0, 1)
	return b * (1 - h) + a * h - k * h * (1 - h)

def field(px, py):
	# px: across the blade (right positive), py: along the blade (tip = 1)
	d = ellipse_sdf(px, py, BODY[1], BODY[0], BODY[2], BODY[3], 0)
	d = smin(d, ellipse_sdf(px, py, 0, TIP[0], TIP[2], TIP[3], 0), BLEND)
	for (t, x, a, b, lean) in RIGHT:
		d = smin(d, ellipse_sdf(px, py, x, t, a, b, lean), BLEND)
	for (t, x, a, b, lean) in LEFT:
		d = smin(d, ellipse_sdf(px, py, -x, t, a, b, -lean), BLEND)
	return d

def to_svg(t, x):
	return (CX + x * LEN, TOP + (1 - t) * LEN)

def trace(n = 600):
	xs = np.linspace(-0.45, 0.45, n)
	ts = np.linspace(-0.08, 1.05, int(n * 1.13 / 0.9))
	X, T = np.meshgrid(xs, ts)
	F = field(X, T)
	inside = F < 0
	rows, cols = F.shape
	def interp(p0, p1, f0, f1):
		r = f0 / (f0 - f1)
		return (p0[0] + (p1[0] - p0[0]) * r, p0[1] + (p1[1] - p0[1]) * r)
	# Marching squares, collecting segments on the zero level
	segs = []
	mixed = np.argwhere((inside[:-1, :-1] != inside[:-1, 1:]) | (inside[:-1, :-1] != inside[1:, :-1]) | (inside[:-1, :-1] != inside[1:, 1:]))
	for j, i in mixed:
		f = [ F[j, i], F[j, i + 1], F[j + 1, i + 1], F[j + 1, i] ]
		p = [ (xs[i], ts[j]), (xs[i + 1], ts[j]), (xs[i + 1], ts[j + 1]), (xs[i], ts[j + 1]) ]
		edges = []
		for e in range(4):
			a, b = e, (e + 1) % 4
			if (f[a] < 0) != (f[b] < 0):
				edges.append(interp(p[a], p[b], f[a], f[b]))
		for k in range(0, len(edges) - 1, 2):
			segs.append((edges[k], edges[k + 1]))
	# Chain segments into one closed loop
	key = lambda p: (round(p[0], 9), round(p[1], 9))
	adj = { }
	for a, b in segs:
		adj.setdefault(key(a), []).append(b)
		adj.setdefault(key(b), []).append(a)
	start = segs[0][0]
	loop, prev, cur = [ start ], None, start
	while True:
		nxt = [ q for q in adj[key(cur)] if prev is None or key(q) != key(prev) ]
		if not nxt: break
		prev, cur = cur, nxt[0]
		if key(cur) == key(start): break
		loop.append(cur)
	return loop

def simplify(pts, eps):
	# Ramer–Douglas–Peucker
	if len(pts) < 3: return pts
	a, b = np.array(pts[0]), np.array(pts[-1])
	ab = b - a
	n = np.linalg.norm(ab) or 1
	dmax, idx = 0, 0
	for i in range(1, len(pts) - 1):
		q = np.array(pts[i]) - a
		d = abs(ab[0] * q[1] - ab[1] * q[0]) / n
		if d > dmax: dmax, idx = d, i
	if dmax > eps:
		return simplify(pts[:idx + 1], eps)[:-1] + simplify(pts[idx:], eps)
	return [ pts[0], pts[-1] ]

def smooth(pts):
	n = len(pts)
	d = "M%.1f,%.1f" % pts[0]
	for i in range(n):
		p0, p1, p2, p3 = pts[(i - 1) % n], pts[i], pts[(i + 1) % n], pts[(i + 2) % n]
		c1 = (p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6)
		c2 = (p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6)
		d += " C%.1f,%.1f %.1f,%.1f %.1f,%.1f" % (c1 + c2 + p2)
	return d + " Z"

def svg(body):
	return '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">%s</svg>\n' % (SIZE, SIZE, SIZE, SIZE, body)

if __name__ == "__main__":
	out = sys.argv[1]
	loop = [ to_svg(t, x) for (x, t) in trace() ]
	half = len(loop) // 2
	pts = simplify(loop[:half + 1], 0.6)[:-1] + simplify(loop[half:] + [ loop[0] ], 0.6)[:-1]
	open(out + "/leaf.svg", "w").write(svg('<path fill="#ffffff" d="%s"/>' % smooth(pts)))
	w = 40
	x0, y0 = to_svg(0.82, 0)
	y1 = TOP + LEN + 190
	open(out + "/caret.svg", "w").write(svg('<rect x="%.1f" y="%.1f" width="%d" height="%.1f" rx="%.1f" fill="#ffffff"/>' % (CX - w / 2, y0, w, y1 - y0, w / 2)))
