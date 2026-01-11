#version 460

layout (location = 0) in vec3 in_translation;
layout (location = 1) in vec4 in_rotation;
layout (location = 2) in vec3 in_scale;

layout (location = 3) in vec3 in_pos;
layout (location = 4) in vec3 in_normal;
layout (location = 5) in vec2 in_texcoord;

void main() {
	gl_Position = vec4(in_pos, 1.0);
}