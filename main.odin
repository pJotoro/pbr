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

    Instance :: struct {
        translation: Vector3,
        rotation: Vector4,
        scale: Vector3,
    }
    #assert(size_of(Instance) == 40)

    Vertex :: struct {
        pos: Vector3,
        normal: Vector3,
        texcoord: Vector2,
    }
    #assert(size_of(Vertex) == 32)

    vertex_input_bindings := [?]vk.VertexInputBindingDescription {
        {
            binding = 0,
            stride = size_of(Instance),
            inputRate = .INSTANCE,
        },
        {
            binding = 1,
            stride = size_of(Vertex),
            inputRate = .VERTEX,
        },
    }

    vertex_input_attributes := [?]vk.VertexInputAttributeDescription {
        {
            location = 0,
            binding = 0,
            format = .R32G32B32_SFLOAT,
            offset = u32(offset_of(Instance, translation)),
        },
        {
            location = 1,
            binding = 0,
            format = .R32G32B32A32_SFLOAT,
            offset = u32(offset_of(Instance, rotation)),
        },
        {
            location = 2,
            binding = 0,
            format = .R32G32B32_SFLOAT,
            offset = u32(offset_of(Instance, scale)),
        },
        {
            location = 3,
            binding = 1,
            format = .R32G32B32_SFLOAT,
            offset = u32(offset_of(Vertex, pos)),
        },
        {
            location = 4,
            binding = 1,
            format = .R32G32B32_SFLOAT,
            offset = u32(offset_of(Vertex, normal)),
        },
        {
            location = 5,
            binding = 1,
            format = .R32G32_SFLOAT,
            offset = u32(offset_of(Vertex, texcoord)),
        },
    }

    vertex_input := vk.PipelineVertexInputStateCreateInfo {
        sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        vertexBindingDescriptionCount = u32(len(vertex_input_bindings)),
        pVertexBindingDescriptions = raw_data(vertex_input_bindings[:]),
        vertexAttributeDescriptionCount = u32(len(vertex_input_attributes)),
        pVertexAttributeDescriptions = raw_data(vertex_input_attributes[:]),
    }

    pipeline: vk.Pipeline
    {
        vert, res1 := vulkan_create_shader_stage(vulkan.device, "build/debug/donut_vert.spv", .VERTEX)
        defer vulkan_destroy_shader_stage(vulkan.device, vert)

        frag, res2 := vulkan_create_shader_stage(vulkan.device, "build/debug/donut_frag.spv", .FRAGMENT)
        defer vulkan_destroy_shader_stage(vulkan.device, frag)

        pipeline, res3 := vulkan_create_graphics_pipeline(&vulkan, shader_stages = {vert, frag}, vertex_input_state = &vertex_input)
    }

    model, res1 := vulkan_load_cgltf(&vulkan, &vulkan_allocator)

    res2 := vulkan_alloc(&vulkan, &vulkan_allocator)
    assert(res1 == .SUCCESS && res2 == .SUCCESS)

    {
        data, _ := vulkan_map_memory_buffer(&vulkan, &vulkan_allocator, model.staging_buffer, 0, vk.DeviceSize(len(model.staging_buffer_data)))
        copy(data, model.staging_buffer_data)
        vulkan_unmap_memory_buffer(&vulkan, &vulkan_allocator, model.staging_buffer)
    }

    for app_update() {
        cb: vk.CommandBuffer
        if command_buffer, res := vulkan_begin_rendering_commands(&vulkan); res != .SUCCESS {
            panic("Unexpected failure occurred.")
        } else {
            cb = command_buffer
        }

        @static staged := false

        if !staged {
            staged = true

            buffer_barriers_before := [?]vk.BufferMemoryBarrier {
                {
                    sType = .BUFFER_MEMORY_BARRIER,
                    srcAccessMask = {},
                    dstAccessMask = {.TRANSFER_READ},
                    buffer = model.staging_buffer,
                    offset = 0,
                    size = vk.DeviceSize(len(model.staging_buffer_data)),
                },
                {
                    sType = .BUFFER_MEMORY_BARRIER,
                    srcAccessMask = {},
                    dstAccessMask = {.TRANSFER_WRITE},
                    buffer = model.vertex_buffer,
                    offset = 0,
                    size = model.vertex_buffer_size,
                },
                {
                    sType = .BUFFER_MEMORY_BARRIER,
                    srcAccessMask = {},
                    dstAccessMask = {.TRANSFER_WRITE},
                    buffer = model.index_buffer,
                    offset = 0,
                    size = model.index_buffer_size,
                },
            }

            vk.CmdPipelineBarrier(
                commandBuffer = cb,
                srcStageMask = {.TOP_OF_PIPE}, dstStageMask = {.TRANSFER},
                dependencyFlags = {},
                memoryBarrierCount = 0, pMemoryBarriers = nil,
                bufferMemoryBarrierCount = u32(len(buffer_barriers_before)), pBufferMemoryBarriers = raw_data(buffer_barriers_before[:]),
                imageMemoryBarrierCount = 0, pImageMemoryBarriers = nil)

            vk.CmdCopyBuffer(
                commandBuffer = cb,
                srcBuffer = model.staging_buffer,
                dstBuffer = model.vertex_buffer,
                regionCount = u32(len(model.vertex_buffer_regions)),
                pRegions = raw_data(model.vertex_buffer_regions[:]))

            vk.CmdCopyBuffer(
                commandBuffer = cb,
                srcBuffer = model.staging_buffer,
                dstBuffer = model.index_buffer,
                regionCount = u32(len(model.index_buffer_regions)),
                pRegions = raw_data(model.index_buffer_regions[:]))

            buffer_barriers_after := [?] vk.BufferMemoryBarrier {
                {
                    sType = .BUFFER_MEMORY_BARRIER,
                    srcAccessMask = {.TRANSFER_WRITE},
                    dstAccessMask = {.VERTEX_ATTRIBUTE_READ},
                    buffer = model.vertex_buffer,
                    offset = 0,
                    size = model.vertex_buffer_size,
                },
                {
                    sType = .BUFFER_MEMORY_BARRIER,
                    srcAccessMask = {.TRANSFER_WRITE},
                    dstAccessMask = {.INDEX_READ},
                    buffer = model.index_buffer,
                    offset = 0,
                    size = model.index_buffer_size,
                },
            }

            vk.CmdPipelineBarrier(
                commandBuffer = cb,
                srcStageMask = {.TRANSFER}, dstStageMask = {.VERTEX_SHADER},
                dependencyFlags = {},
                memoryBarrierCount = 0, pMemoryBarriers = nil,
                bufferMemoryBarrierCount = u32(len(buffer_barriers_after)), pBufferMemoryBarriers = raw_data(buffer_barriers_after[:]),
                imageMemoryBarrierCount = 0, pImageMemoryBarriers = nil)
        }

        vulkan_begin_rendering(&vulkan, 0.0, 0.0, 0.0, 0.0)
        {
            vk.CmdBindPipeline(cb, .GRAPHICS, pipeline)
            offset: vk.DeviceSize = 0
            vk.CmdBindVertexBuffers(
                commandBuffer = cb,
                firstBinding = 0, bindingCount = 1,
                pBuffers = &model.vertex_buffer, pOffsets = &offset)
            vk.CmdBindIndexBuffer(
                commandBuffer = cb,
                buffer = model.index_buffer,
                offset = 0,
                indexType = .UINT16)
            vk.CmdDrawIndexed(
                commandBuffer = cb,
                indexCount = u32(model.index_buffer_size/size_of(u16)), instanceCount = u32(model.vertex_buffer_size/size_of(Instance)),
                firstIndex = 0, vertexOffset = 0, firstInstance = 0)
        }
        vulkan_end_rendering(&vulkan)

        if res := vulkan_end_rendering_commands(&vulkan); res != .SUCCESS {
            panic("Unexpected failure occurred.")
        }

        free_all(context.temp_allocator)
    }
}