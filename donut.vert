#version 460

layout (location = 0) in vec3 in_pos;
layout (location = 1) in vec3 in_normal;
layout (location = 2) in vec2 in_texcoord;

layout (binding = 0, set = 0) uniform Uniform {
	vec3 translation;
	vec4 rotation;
	vec3 scale;
} u;

void main() {
	vec4 pos = vec4(in_pos, 1.0);
	pos.xyz += u.translation;
	// TODO: Rotation
	pos.xyz *= u.scale;

	gl_Position = pos;
}