class_name HareChaseGeometry
extends RefCounted
## Pure geometry for the hare chase mini game. No nodes, no scene access, so it
## can be unit-tested headlessly.
##
## The open play area is always a CONVEX polygon: it starts as a rectangle and
## every valid cut is a chord between two boundary points, so each half is
## convex too. That keeps point tests and splitting exact and cheap.


## Rectangle -> polygon (clockwise in screen space: TL, TR, BR, BL).
static func rect_to_polygon(rect: Rect2) -> PackedVector2Array:
	return PackedVector2Array([
		rect.position,
		Vector2(rect.end.x, rect.position.y),
		rect.end,
		Vector2(rect.position.x, rect.end.y),
	])


## Absolute polygon area (shoelace).
static func polygon_area(poly: PackedVector2Array) -> float:
	var n: int = poly.size()
	if n < 3:
		return 0.0
	var sum: float = 0.0
	for i in range(n):
		var p: Vector2 = poly[i]
		var q: Vector2 = poly[(i + 1) % n]
		sum += p.x * q.y - q.x * p.y
	return absf(sum) * 0.5


## Closest point on the polygon's boundary to `p`.
## Returns { "point": Vector2, "edge": int, "dist": float } where `edge` is the
## index i of the edge from poly[i] to poly[(i+1) % n].
static func closest_boundary(poly: PackedVector2Array, p: Vector2) -> Dictionary:
	var best_point: Vector2 = Vector2.ZERO
	var best_edge: int = -1
	var best_dist: float = INF
	var n: int = poly.size()
	for i in range(n):
		var a: Vector2 = poly[i]
		var b: Vector2 = poly[(i + 1) % n]
		var cp: Vector2 = Geometry2D.get_closest_point_to_segment(p, a, b)
		var d: float = p.distance_to(cp)
		if d < best_dist:
			best_dist = d
			best_point = cp
			best_edge = i
	return {"point": best_point, "edge": best_edge, "dist": best_dist}


## Distance from `p` to the polygon boundary.
static func boundary_distance(poly: PackedVector2Array, p: Vector2) -> float:
	return float(closest_boundary(poly, p)["dist"])


## True if `p` is inside the polygon (boundary counts as inside, within tol).
static func contains(poly: PackedVector2Array, p: Vector2, tol: float = 1.0) -> bool:
	if poly.size() < 3:
		return false
	if Geometry2D.is_point_in_polygon(p, poly):
		return true
	return boundary_distance(poly, p) <= tol


## True if `p` is inside the polygon and at least `margin` away from every edge.
static func contains_with_margin(poly: PackedVector2Array, p: Vector2, margin: float) -> bool:
	if poly.size() < 3:
		return false
	if not Geometry2D.is_point_in_polygon(p, poly):
		return false
	return boundary_distance(poly, p) >= margin


## True if segment a-b touches or crosses the rectangle.
static func segment_hits_rect(a: Vector2, b: Vector2, rect: Rect2) -> bool:
	if rect.has_point(a) or rect.has_point(b):
		return true
	var tl: Vector2 = rect.position
	var tr: Vector2 = Vector2(rect.end.x, rect.position.y)
	var br: Vector2 = rect.end
	var bl: Vector2 = Vector2(rect.position.x, rect.end.y)
	var edges: Array = [[tl, tr], [tr, br], [br, bl], [bl, tl]]
	for e in edges:
		var hit = Geometry2D.segment_intersects_segment(a, b, e[0], e[1])
		if hit != null:
			return true
	return false


## Removes consecutive (and wrap-around) near-duplicate points.
static func dedupe(poly: PackedVector2Array, eps: float = 0.5) -> PackedVector2Array:
	var out: PackedVector2Array = PackedVector2Array()
	for p in poly:
		if out.is_empty() or out[out.size() - 1].distance_to(p) > eps:
			out.append(p)
	while out.size() > 1 and out[0].distance_to(out[out.size() - 1]) <= eps:
		out.remove_at(out.size() - 1)
	return out


## Attempts to cut the convex `poly` with a straight stroke from raw_a to raw_b.
##
## Both stroke ends must land within `snap_dist` of the polygon boundary (an
## outer wall or an earlier cut) — that is the "edge to edge" rule. The ends are
## snapped onto the boundary. The chord must be at least `min_len` long and must
## leave two real pieces (so a stroke running along one edge is rejected).
##
## Returns:
##   { "ok": false, "reason": "edge" | "short" | "degenerate" }
##   { "ok": true, "a": Vector2, "b": Vector2, "polys": [PackedVector2Array, PackedVector2Array] }
static func try_cut(poly: PackedVector2Array, raw_a: Vector2, raw_b: Vector2,
		snap_dist: float, min_len: float) -> Dictionary:
	if poly.size() < 3:
		return {"ok": false, "reason": "degenerate"}

	var ca: Dictionary = closest_boundary(poly, raw_a)
	var cb: Dictionary = closest_boundary(poly, raw_b)
	if float(ca["dist"]) > snap_dist or float(cb["dist"]) > snap_dist:
		return {"ok": false, "reason": "edge"}

	var a: Vector2 = ca["point"]
	var b: Vector2 = cb["point"]
	var ia: int = int(ca["edge"])
	var ib: int = int(cb["edge"])
	if a.distance_to(b) < min_len:
		return {"ok": false, "reason": "short"}
	if ia == ib:
		return {"ok": false, "reason": "degenerate"}

	## Order so ia < ib.
	if ia > ib:
		var tp: Vector2 = a
		a = b
		b = tp
		var ti: int = ia
		ia = ib
		ib = ti

	var n: int = poly.size()

	## Piece 1: a -> v[ia+1 .. ib] -> b
	var p1: PackedVector2Array = PackedVector2Array()
	p1.append(a)
	for k in range(ia + 1, ib + 1):
		p1.append(poly[k])
	p1.append(b)

	## Piece 2: b -> v[ib+1 .. n-1, 0 .. ia] -> a
	var p2: PackedVector2Array = PackedVector2Array()
	p2.append(b)
	var k2: int = (ib + 1) % n
	var guard: int = 0
	while guard <= n:
		p2.append(poly[k2])
		if k2 == ia:
			break
		k2 = (k2 + 1) % n
		guard += 1
	p2.append(a)

	p1 = dedupe(p1)
	p2 = dedupe(p2)

	var min_area: float = min_len * min_len * 0.25
	if polygon_area(p1) < min_area or polygon_area(p2) < min_area:
		return {"ok": false, "reason": "degenerate"}

	return {"ok": true, "a": a, "b": b, "polys": [p1, p2]}


## Random point inside the polygon, at least `margin` from every edge.
## Falls back to the centroid if no point is found (very small areas).
static func random_point_inside(poly: PackedVector2Array, margin: float,
		rng: RandomNumberGenerator) -> Vector2:
	var minx: float = INF
	var miny: float = INF
	var maxx: float = -INF
	var maxy: float = -INF
	for p in poly:
		minx = minf(minx, p.x)
		miny = minf(miny, p.y)
		maxx = maxf(maxx, p.x)
		maxy = maxf(maxy, p.y)
	for _i in range(60):
		var c: Vector2 = Vector2(rng.randf_range(minx, maxx), rng.randf_range(miny, maxy))
		if contains_with_margin(poly, c, margin):
			return c
	return centroid(poly)


## Vertex-average centroid (fine for the convex shapes used here).
static func centroid(poly: PackedVector2Array) -> Vector2:
	if poly.is_empty():
		return Vector2.ZERO
	var s: Vector2 = Vector2.ZERO
	for p in poly:
		s += p
	return s / float(poly.size())
