#version 460

layout (binding = 0, set = 0) uniform Uniforms {
	mat4 model;
	mat4 view;
	mat4 proj;
} u;

void main() {
	vec2 vertices[6] = {
	    vec2(0.5, 0.5),
	    vec2(0.5, -0.5),
	    vec2(-0.5, 0.5),
	    vec2(0.5, -0.5),
	    vec2(-0.5, -0.5),
	    vec2(-0.5, 0.5),
	};
	vec4 pos = vec4(vertices[gl_VertexIndex], 0.0, 1.0);
	
	gl_Position = u.proj * u.view * u.model * pos;
}