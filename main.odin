package pbr

import "base:intrinsics"

import "core:mem"
import "core:math/linalg"

import vk "vendor:vulkan"

APP_TOPMOST :: #config(APP_TOPMOST, !ODIN_DEBUG)

VULKAN_DEBUG :: #config(VULKAN_DEBUG, ODIN_DEBUG)
VULKAN_VALIDATION :: #config(VULKAN_VALIDATION, VULKAN_DEBUG)
VULKAN_DEBUG_UTILS :: #config(VULKAN_DEBUG_UTILS, VULKAN_DEBUG)
VULKAN_LAYERS :: #config(VULKAN_LAYERS, VULKAN_DEBUG)
VULKAN_DISABLE_PIPELINE_OPTIMIZATION :: #config(VULKAN_DISABLE_PIPELINE_OPTIMIZATION, VULKAN_DEBUG)

π :: linalg.π

Vector2 :: linalg.Vector2f32
Vector3 :: linalg.Vector3f32
Vector4 :: linalg.Vector4f32

main :: proc() {
    context.assertion_failure_proc = assertion_failure_proc

    w, h, refresh_rate := app_init()
    dt := 1.0/f32(refresh_rate)

    vulkan: Vulkan
    vulkan.arena = mem.arena_allocator(&{data = make([]byte, mem.Megabyte)})
    if res := vulkan_init(&vulkan, vk.API_VERSION_1_1, vk.API_VERSION_1_1); res != .SUCCESS {
        panic("Unexpected failure occurred.")
    }

    vulkan_allocator := vulkan_create_allocator()

    cube: Cube
    if res := cube_init(&vulkan, &vulkan_allocator, &cube); res != .SUCCESS {
        panic("Unexpected failure occurred.")
    }

    // Instance :: struct {
    //     translation: Vector3,
    //     rotation: Vector4,
    //     scale: Vector3,
    // }
    // #assert(size_of(Instance) == 40)

    // Vertex :: struct {
    //     pos: Vector3,
    //     normal: Vector3,
    //     texcoord: Vector2,
    // }
    // #assert(size_of(Vertex) == 32)

    // vertex_input_bindings := [?]vk.VertexInputBindingDescription {
    //     {
    //         binding = 0,
    //         stride = size_of(Instance),
    //         inputRate = .INSTANCE,
    //     },
    //     {
    //         binding = 1,
    //         stride = size_of(Vertex),
    //         inputRate = .VERTEX,
    //     },
    // }

    // vertex_input_attributes := [?]vk.VertexInputAttributeDescription {
    //     {
    //         location = 0,
    //         binding = 0,
    //         format = .R32G32B32_SFLOAT,
    //         offset = u32(offset_of(Instance, translation)),
    //     },
    //     {
    //         location = 1,
    //         binding = 0,
    //         format = .R32G32B32A32_SFLOAT,
    //         offset = u32(offset_of(Instance, rotation)),
    //     },
    //     {
    //         location = 2,
    //         binding = 0,
    //         format = .R32G32B32_SFLOAT,
    //         offset = u32(offset_of(Instance, scale)),
    //     },
    //     {
    //         location = 0,
    //         binding = 1,
    //         format = .R32G32B32_SFLOAT,
    //         offset = u32(offset_of(Vertex, pos)),
    //     },
    //     {
    //         location = 1,
    //         binding = 1,
    //         format = .R32G32B32_SFLOAT,
    //         offset = u32(offset_of(Vertex, normal)),
    //     },
    //     {
    //         location = 2,
    //         binding = 1,
    //         format = .R32G32_SFLOAT,
    //         offset = u32(offset_of(Vertex, texcoord)),
    //     },
    // }

    // vertex_input := vk.PipelineVertexInputStateCreateInfo {
    //     sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    //     vertexBindingDescriptionCount = u32(len(vertex_input_bindings)),
    //     pVertexBindingDescriptions = raw_data(vertex_input_bindings[:]),
    //     vertexAttributeDescriptionCount = u32(len(vertex_input_attributes)),
    //     pVertexAttributeDescriptions = raw_data(vertex_input_attributes[:]),
    // }

    for app_update() {
        if res := cube_update(&vulkan, &vulkan_allocator, &cube, f32(w)/f32(h), dt); res != .SUCCESS {
            panic("Unexpected failure occurred.")
        }

        cb: vk.CommandBuffer
        if command_buffer, res := vulkan_begin_rendering_commands(&vulkan); res != .SUCCESS {
            panic("Unexpected failure occurred.")
        } else {
            cb = command_buffer
        }

        cube_barriers(cb, &cube)

        vulkan_begin_rendering(&vulkan, 0.0, 0.0, 0.0, 0.0)
        cube_draw(cb, &cube)
        vulkan_end_rendering(&vulkan)

        if res := vulkan_end_rendering_commands(&vulkan); res != .SUCCESS {
            panic("Unexpected failure occurred.")
        }

        free_all(context.temp_allocator)
    }
}