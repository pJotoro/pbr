package pbr

import "base:intrinsics"
import "base:runtime"

import "core:os"

import "vendor:cgltf"
import vk "vendor:vulkan"

cgltf_load :: proc(name: string) -> (out_data: ^cgltf.data, res: cgltf.result) {
    file_data, ok := os.read_entire_file(name, context.temp_allocator)
    if !ok {
        res = .file_not_found
        return
    }

    alloc_proc :: proc "c" (user: rawptr, size: uint) -> rawptr {
        context = runtime.default_context()
        data := make([]byte, size, context.temp_allocator)
        return raw_data(data)
    }

    free_proc :: proc "c" (user: rawptr, ptr: rawptr) {

    }

    memory_options := cgltf.memory_options {
        alloc_func = alloc_proc,
        free_func = free_proc,
        user_data = nil,
    }

    options := cgltf.options {
        type = .glb,
        memory = memory_options,
    }

    return cgltf.parse(options, raw_data(file_data), len(file_data))
}

Model :: struct {
	vertex_buffer_regions: [dynamic]vk.BufferCopy,
	index_buffer_regions: [dynamic]vk.BufferCopy,
	vertex_buffer: vk.Buffer,
	index_buffer: vk.Buffer,
	staging_buffer: vk.Buffer,
	staging_buffer_data: []byte,
}

vulkan_load_cgltf :: proc(vulkan: ^Vulkan, vulkan_allocator: ^Vulkan_Allocator) -> Model {
	/*
	Parts of gltf file I don't handle yet that I have to:

	meshes
	materials
	accessors
	nodes
	extensions    
	*/

	vertex_buffer_size: vk.DeviceSize
	vertex_buffer_regions := make([dynamic]vk.BufferCopy)

	index_buffer_size: vk.DeviceSize
	index_buffer_regions := make([dynamic]vk.BufferCopy)

	data, res := cgltf_load("assets/chocolate_donut.glb")
	assert(res == .success)

	assert(data.file_type == .glb)
	assert(data.file_data == nil)
	assert(data.asset.version == "2.0")
	assert(data.asset.extras == {})
	assert(data.asset.extensions_count == 0)

	for mesh in data.meshes {
		assert(mesh.name != "")

		for primitive in mesh.primitives {
			assert(primitive.type == .triangles)
			assert(primitive.indices != nil)
			assert(primitive.material != nil)
			
			assert(len(primitive.attributes) == 3)
			stride := uint(0)
			assert(primitive.attributes[0].name == "POSITION")
			assert(primitive.attributes[0].type == .position)
			assert(primitive.attributes[0].index == 0)
			stride += primitive.attributes[0].data.stride
			assert(vulkan_get_format(primitive.attributes[0].data.component_type, primitive.attributes[0].data.type) == .R32G32B32_SFLOAT)
			assert(primitive.attributes[1].name == "NORMAL")
			assert(primitive.attributes[1].type == .normal)
			assert(primitive.attributes[1].index == 0)
			assert(vulkan_get_format(primitive.attributes[1].data.component_type, primitive.attributes[1].data.type) == .R32G32B32_SFLOAT)
			stride += primitive.attributes[1].data.stride
			assert(primitive.attributes[2].name == "TEXCOORD_0")
			assert(primitive.attributes[2].type == .texcoord)
			assert(primitive.attributes[2].index == 0)
			assert(vulkan_get_format(primitive.attributes[2].data.component_type, primitive.attributes[2].data.type) == .R32G32_SFLOAT)
			stride += primitive.attributes[2].data.stride

			assert(primitive.targets == nil)
			assert(primitive.extras.data == nil)
			assert(!primitive.has_draco_mesh_compression)
			assert(primitive.mappings == nil)
			assert(primitive.extensions_count == 0)
		}

		assert(mesh.weights == nil)
		assert(mesh.target_names == nil)
		assert(mesh.extras == {})
		assert(mesh.extensions_count == 0)
	}

	for material in data.materials {
		assert(material.name != "")

		assert(material.has_pbr_metallic_roughness == true)
		assert(material.pbr_metallic_roughness.base_color_texture == {})
		assert(material.pbr_metallic_roughness.metallic_roughness_texture == {})
		assert(material.pbr_metallic_roughness.base_color_factor != {})
		assert(material.pbr_metallic_roughness.metallic_factor == 0)
		assert(material.pbr_metallic_roughness.roughness_factor != 0.0)

		assert(!material.has_pbr_specular_glossiness)
		assert(material.pbr_specular_glossiness.diffuse_texture == {})
		assert(material.pbr_specular_glossiness.specular_glossiness_texture == {})
		assert(material.pbr_specular_glossiness.diffuse_factor == {1, 1, 1, 1})
		assert(material.pbr_specular_glossiness.specular_factor == {1, 1, 1})
		assert(material.pbr_specular_glossiness.glossiness_factor == 1)
		
		assert(material.has_clearcoat == false)
		assert(material.clearcoat == {})

		assert(!material.has_transmission)
		assert(material.transmission == {})

		assert(!material.has_volume)
		assert(material.volume.thickness_texture == {})
		assert(material.volume.thickness_factor == 0)
		assert(material.volume.attenuation_color == {1, 1, 1})
		assert(material.volume.attenuation_distance != 0.0)
		
		if material.has_ior {
			// material.ior
		}

		if material.has_specular {
			// material.specular
		}

		assert(!material.has_sheen)
		assert(material.sheen == {})

		assert(!material.has_emissive_strength)
		assert(material.emissive_strength == {})

		assert(!material.has_iridescence)
		assert(material.iridescence == {})

		assert(!material.has_anisotropy)
		assert(material.anisotropy == {})

		assert(!material.has_dispersion)
		assert(material.dispersion == {})

		assert(material.normal_texture == {})
		assert(material.occlusion_texture == {})
		assert(material.emissive_texture == {})
		assert(material.emissive_factor == {})

		assert(material.alpha_mode == .opaque)
		assert(material.alpha_cutoff == 0.5)
		assert(material.double_sided == true)
		assert(!material.unlit)
		assert(material.extras == {})
		assert(material.extensions_count == 0)
	}

	for accessor in data.accessors {
		assert(accessor.name == "")

		vulkan_format := vulkan_get_format(accessor.component_type, accessor.type)
		assert(vulkan_format != .UNDEFINED)

		assert(!accessor.normalized)
		assert(accessor.offset == 0)
		// accessor.count
		// accessor.stride

		assert(accessor.buffer_view != nil)
		assert(accessor.buffer_view.buffer != nil)

		if accessor.has_min {
			// accessor.min
		}

		if accessor.has_max {
			// accessor.max
		}

		assert(!accessor.is_sparse)
		assert(accessor.sparse == {})

		assert(accessor.extras == {})
		assert(accessor.extensions_count == 0)
	}

	for buffer_view in data.buffer_views {
		// buffer_view.name
		assert(buffer_view.buffer != nil)
		assert(buffer_view.stride == 0)
		switch buffer_view.type {
			case .invalid:

			case .vertices:
				append(&vertex_buffer_regions, vk.BufferCopy{
					srcOffset = vk.DeviceSize(buffer_view.offset),
					dstOffset = vertex_buffer_size,
					size = vk.DeviceSize(buffer_view.size),
				})
				vertex_buffer_size += vk.DeviceSize(buffer_view.size)
			case .indices:
				append(&index_buffer_regions, vk.BufferCopy{
					srcOffset = vk.DeviceSize(buffer_view.offset),
					dstOffset = index_buffer_size,
					size = vk.DeviceSize(buffer_view.size),
				})
				index_buffer_size += vk.DeviceSize(buffer_view.size)
		}
		assert(buffer_view.data == nil)
		assert(!buffer_view.has_meshopt_compression)
		assert(buffer_view.meshopt_compression == {})
		assert(buffer_view.extras == {})
		assert(buffer_view.extensions_count == 0)
	}

	assert(len(data.buffers) == 1)
	// buffer{
	// 	name = "",
	// 	size = 1756,
	// 	uri = "",
	// 	data = 0x0,
	// 	data_free_method = "none",
	// 	extras = extras_t{
	// 		start_offset = 0,
	// 		end_offset = 0,
	// 		data = <nil>,
	// 	},
	// 	extensions_count = 0,
	// 	extensions = <nil>,
	// }

	assert(len(data.images) == 0)
	assert(len(data.textures) == 0)
	assert(len(data.samplers) == 0)
	assert(len(data.skins) == 0)
	assert(len(data.cameras) == 0)
	assert(len(data.lights) == 0)

	for node in data.nodes {
		assert(node.name != "")
		if node.parent != nil {
			// node.parent
		}
		if node.children != nil {
			// node.children
		}
		assert(node.skin == nil)
		assert(node.mesh != nil)
		assert(node.camera == nil)
		assert(node.light == nil)
		assert(node.weights == nil)
		assert(node.has_translation == true)
		// node.translation
		if node.has_rotation {
			// node.rotation
		}
		if node.has_scale {
			// node.scale
		}
		assert(!node.has_matrix)
		assert(node.extras == {})
		assert(!node.has_mesh_gpu_instancing)
		assert(node.extensions_count == 0)
	}

	assert(len(data.scenes) == 1)
	// scene{
	// 	name = "Scene",
	// 	nodes = [
	// 		&node{
	// 			name = "Donut",
	// 			parent = <nil>,
	// 			children = [],
	// 			skin = <nil>,
	// 			mesh = 0x21C6DEF7EAE,
	// 			camera = <nil>,
	// 			light = <nil>,
	// 			weights = [],
	// 			has_translation = true,
	// 			has_rotation = true,
	// 			has_scale = true,
	// 			has_matrix = false,
	// 			translation = [
	// 				0,
	// 				0.025177613,
	// 				0,
	// 			],
	// 			rotation = [
	// 				0,
	// 				-0.7889224,
	// 				0,
	// 				0.61449289,
	// 			],
	// 			scale = [
	// 				1,
	// 				1.0000026,
	// 				1,
	// 			],
	// 			matrix_ = [
	// 				1,
	// 				0,
	// 				0,
	// 				0,
	// 				0,
	// 				1,
	// 				0,
	// 				0,
	// 				0,
	// 				0,
	// 				1,
	// 				0,
	// 				0,
	// 				0,
	// 				0,
	// 				1,
	// 			],
	// 			extras = extras_t{
	// 				start_offset = 0,
	// 				end_offset = 0,
	// 				data = <nil>,
	// 			},
	// 			has_mesh_gpu_instancing = false,
	// 			mesh_gpu_instancing = mesh_gpu_instancing{
	// 				attributes = [],
	// 			},
	// 			extensions_count = 0,
	// 			extensions = <nil>,
	// 		},
	// 		&node{
	// 			name = "Table",
	// 			parent = <nil>,
	// 			children = [],
	// 			skin = <nil>,
	// 			mesh = 0x21C6DEF7F0E,
	// 			camera = <nil>,
	// 			light = <nil>,
	// 			weights = [],
	// 			has_translation = true,
	// 			has_rotation = false,
	// 			has_scale = true,
	// 			has_matrix = false,
	// 			translation = [
	// 				-1.2678384,
	// 				-0.001,
	// 				-3.2460144,
	// 			],
	// 			rotation = [
	// 				0,
	// 				0,
	// 				0,
	// 				1,
	// 			],
	// 			scale = [
	// 				0.33391109,
	// 				0.33391109,
	// 				0.33391109,
	// 			],
	// 			matrix_ = [
	// 				1,
	// 				0,
	// 				0,
	// 				0,
	// 				0,
	// 				1,
	// 				0,
	// 				0,
	// 				0,
	// 				0,
	// 				1,
	// 				0,
	// 				0,
	// 				0,
	// 				0,
	// 				1,
	// 			],
	// 			extras = extras_t{
	// 				start_offset = 0,
	// 				end_offset = 0,
	// 				data = <nil>,
	// 			},
	// 			has_mesh_gpu_instancing = false,
	// 			mesh_gpu_instancing = mesh_gpu_instancing{
	// 				attributes = [],
	// 			},
	// 			extensions_count = 0,
	// 			extensions = <nil>,
	// 		},
	// 		&node{
	// 			name = "Abstract Plate",
	// 			parent = <nil>,
	// 			children = [],
	// 			skin = <nil>,
	// 			mesh = 0x21C6DEF7F6E,
	// 			camera = <nil>,
	// 			light = <nil>,
	// 			weights = [],
	// 			has_translation = true,
	// 			has_rotation = false,
	// 			has_scale = false,
	// 			has_matrix = false,
	// 			translation = [
	// 				0,
	// 				0.0051408298,
	// 				0,
	// 			],
	// 			rotation = [
	// 				0,
	// 				0,
	// 				0,
	// 				1,
	// 			],
	// 			scale = [
	// 				1,
	// 				1,
	// 				1,
	// 			],
	// 			matrix_ = [
	// 				1,
	// 				0,
	// 				0,
	// 				0,
	// 				0,
	// 				1,
	// 				0,
	// 				0,
	// 				0,
	// 				0,
	// 				1,
	// 				0,
	// 				0,
	// 				0,
	// 				0,
	// 				1,
	// 			],
	// 			extras = extras_t{
	// 				start_offset = 0,
	// 				end_offset = 0,
	// 				data = <nil>,
	// 			},
	// 			has_mesh_gpu_instancing = false,
	// 			mesh_gpu_instancing = mesh_gpu_instancing{
	// 				attributes = [],
	// 			},
	// 			extensions_count = 0,
	// 			extensions = <nil>,
	// 		},
	// 		&node{
	// 			name = "Vast",
	// 			parent = <nil>,
	// 			children = [
	// 				0x21C6DEF641A,
	// 			],
	// 			skin = <nil>,
	// 			mesh = 0x21C6DEF802E,
	// 			camera = <nil>,
	// 			light = <nil>,
	// 			weights = [],
	// 			has_translation = true,
	// 			has_rotation = false,
	// 			has_scale = false,
	// 			has_matrix = false,
	// 			translation = [
	// 				0.27141318,
	// 				0,
	// 				-0.22245401,
	// 			],
	// 			rotation = [
	// 				0,
	// 				0,
	// 				0,
	// 				1,
	// 			],
	// 			scale = [
	// 				1,
	// 				1,
	// 				1,
	// 			],
	// 			matrix_ = [
	// 				1,
	// 				0,
	// 				0,
	// 				0,
	// 				0,
	// 				1,
	// 				0,
	// 				0,
	// 				0,
	// 				0,
	// 				1,
	// 				0,
	// 				0,
	// 				0,
	// 				0,
	// 				1,
	// 			],
	// 			extras = extras_t{
	// 				start_offset = 0,
	// 				end_offset = 0,
	// 				data = <nil>,
	// 			},
	// 			has_mesh_gpu_instancing = false,
	// 			mesh_gpu_instancing = mesh_gpu_instancing{
	// 				attributes = [],
	// 			},
	// 			extensions_count = 0,
	// 			extensions = <nil>,
	// 		},
	// 	],
	// 	extras = extras_t{
	// 		start_offset = 0,
	// 		end_offset = 0,
	// 		data = <nil>,
	// 	},
	// 	extensions_count = 0,
	// 	extensions = <nil>,
	// }

	assert(data.animations == nil)
	assert(data.variants == nil)
	// data.extensions_used = ["KHR_materials_specular", "KHR_materials_ior"]
	assert(data.extensions_required == nil)

	assert(vertex_buffer_size + index_buffer_size == vk.DeviceSize(len(data.bin)))

	vertex_buffer, _ := vulkan_create_buffer(vulkan, vulkan_allocator, 
		vertex_buffer_size, 
		{.TRANSFER_DST, .VERTEX_BUFFER}, {.DEVICE_LOCAL}, {.HOST_VISIBLE})

	index_buffer, _ := vulkan_create_buffer(vulkan, vulkan_allocator, 
		index_buffer_size, 
		{.TRANSFER_DST, .INDEX_BUFFER}, {.DEVICE_LOCAL}, {.HOST_VISIBLE})

	staging_buffer, _ := vulkan_create_buffer(vulkan, vulkan_allocator, 
		vertex_buffer_size + index_buffer_size, 
		{.TRANSFER_SRC}, {.HOST_VISIBLE, .HOST_COHERENT}, {.DEVICE_LOCAL})

	model := Model {
		vertex_buffer_regions = vertex_buffer_regions,
		index_buffer_regions = index_buffer_regions,
		vertex_buffer = vertex_buffer,
		index_buffer = staging_buffer,
		staging_buffer = staging_buffer,
		staging_buffer_data = make([]byte, vertex_buffer_size + index_buffer_size)
	}
	copy(model.staging_buffer_data, data.bin)

	return model
}

vulkan_get_format_from_cgltf_component_type_and_cgltf_type :: #force_inline proc "contextless" (cgltf_component_type: cgltf.component_type, cgltf_type: cgltf.type) -> vk.Format {
    #partial switch cgltf_component_type {
        case .r_8:
            #partial switch cgltf_type {
                case .scalar:
                    return .R8_SINT
                case .vec2:
                    return .R8G8_SINT
                case .vec3:
                    return .R8G8B8_SINT
                case .vec4:
                    return .R8G8B8A8_SINT
            }
        case .r_8u:
            #partial switch cgltf_type {
                case .scalar:
                    return .R8_UINT
                case .vec2:
                    return .R8G8_UINT
                case .vec3:
                    return .R8G8B8_UINT
                case .vec4:
                    return .R8G8B8A8_UINT
            }
        case .r_16:
            #partial switch cgltf_type {
                case .scalar:
                    return .R16_SINT
                case .vec2:
                    return .R16G16_SINT
                case .vec3:
                    return .R16G16B16_SINT
                case .vec4:
                    return .R16G16B16A16_SINT
            }
        case .r_16u:
            #partial switch cgltf_type {
                case .scalar:
                    return .R16_UINT
                case .vec2:
                    return .R16G16_UINT
                case .vec3:
                    return .R16G16B16_UINT
                case .vec4:
                    return .R16G16B16A16_UINT
            }
        case .r_32u:
            #partial switch cgltf_type {
                case .scalar:
                    return .R32_UINT
                case .vec2:
                    return .R32G32_UINT
                case .vec3:
                    return .R32G32B32_UINT
                case .vec4:
                    return .R32G32B32A32_UINT
            }
        case .r_32f:
            #partial switch cgltf_type {
                case .scalar:
                    return .R32_SFLOAT
                case .vec2:
                    return .R32G32_SFLOAT
                case .vec3:
                    return .R32G32B32_SFLOAT
                case .vec4:
                    return .R32G32B32A32_SFLOAT
            }
    }

    return .UNDEFINED
}