shader_type spatial;
// Skybound platforms: a dark body that brightens toward the top, a faint grid on the top face and a glowing
// outline on the box edges. Size and colour come per instance, so every platform shares one material.

instance uniform vec4 tint : source_color = vec4(0.22, 0.71, 1.0, 1.0);
instance uniform vec3 half_size = vec3(3.0, 0.5, 3.0);
uniform float edge_width = 0.08;
uniform float glow = 2.4;

varying vec3 lpos;
varying vec3 lnormal;

void vertex() {
	lpos = VERTEX;
	lnormal = NORMAL;
}

void fragment() {
	vec3 d = half_size - abs(lpos);
	float near = step(d.x, edge_width) + step(d.y, edge_width) + step(d.z, edge_width);
	float edge = step(2.0, near);
	float h = clamp(lpos.y / max(half_size.y, 0.001) * 0.5 + 0.5, 0.0, 1.0);
	vec3 body = mix(tint.rgb * 0.16, tint.rgb * 0.34, h);
	float top = step(0.9, lnormal.y);
	body = mix(body, tint.rgb * 0.5 + vec3(0.05), top);
	vec2 g = abs(fract(lpos.xz * 0.5) - 0.5);
	float grid = top * (1.0 - smoothstep(0.0, 0.035, min(g.x, g.y))) * 0.22;
	ALBEDO = body + tint.rgb * grid;
	EMISSION = tint.rgb * (edge * glow + grid * 0.5 + 0.14);
	ROUGHNESS = 0.85;
}
