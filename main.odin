package pbr

import "base:intrinsics"
import "core:mem"
import vk "vendor:vulkan"
import "core:debug/trace"
import "core:math/linalg"

APP_TOPMOST :: #config(APP_TOPMOST, !ODIN_DEBUG)

VULKAN_DEBUG :: #config(VULKAN_DEBUG, ODIN_DEBUG)
VULKAN_VALIDATION :: #config(VULKAN_VALIDATION, VULKAN_DEBUG)
VULKAN_DEBUG_UTILS :: #config(VULKAN_DEBUG_UTILS, VULKAN_DEBUG)
VULKAN_LAYERS :: #config(VULKAN_LAYERS, VULKAN_DEBUG)
VULKAN_DISABLE_PIPELINE_OPTIMIZATION :: #config(VULKAN_DISABLE_PIPELINE_OPTIMIZATION, VULKAN_DEBUG)

STACK_TRACE :: #config(STACK_TRACE, ODIN_DEBUG)

π :: linalg.π

Vector3 :: linalg.Vector3f32

main :: proc() {
    when STACK_TRACE {
        trace.init(&global_trace_ctx)
        context.assertion_failure_proc = debug_trace_assertion_failure_proc
    }

    w, h, refresh_rate := app_init()
    dt := 1.0/f32(refresh_rate)

    vulkan: Vulkan
    vulkan.arena = mem.arena_allocator(&{data = make([]byte, mem.Megabyte)})
    if res := vulkan_init(&vulkan, vk.API_VERSION_1_1, vk.API_VERSION_1_1); res != .SUCCESS {
        app_panic("Your graphics driver is out of date.")
    }

    Uniforms :: struct {
        model: matrix[4, 4]f32,
        view: matrix[4, 4]f32,
        proj: matrix[4, 4]f32,
    }
    u: Uniforms

    vulkan_allocator := vulkan_create_allocator()

    uniform_buffer: vk.Buffer
    if b, res := vulkan_create_buffer(&vulkan, &vulkan_allocator, size_of(Uniforms), {.TRANSFER_DST, .UNIFORM_BUFFER}, {.DEVICE_LOCAL}, {.HOST_VISIBLE}); res != .SUCCESS {
        app_panic("Failed to create uniform buffer.")
    } else {
        uniform_buffer = b
    }

    staging_buffer: vk.Buffer
    if b, res := vulkan_create_buffer(&vulkan, &vulkan_allocator, size_of(Uniforms), {.TRANSFER_SRC}, {.HOST_VISIBLE, .HOST_COHERENT}, {.DEVICE_LOCAL}); res != .SUCCESS {
        app_panic("Failed to create staging buffer.")
    } else {
        staging_buffer = b
    }

    if res := vulkan_alloc(&vulkan, &vulkan_allocator); res != .SUCCESS {
        app_panic("Failed to allocate GPU memory.")
    }

    descriptor_set_layout: vk.DescriptorSetLayout
    descriptor_set_layout_binding := vk.DescriptorSetLayoutBinding {
        binding = 0,
        descriptorType = .UNIFORM_BUFFER,
        descriptorCount = 1,
        stageFlags = {.VERTEX},
    }
    descriptor_set_layout_info := vk.DescriptorSetLayoutCreateInfo {
        sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        bindingCount = 1,
        pBindings = &descriptor_set_layout_binding,
    }
    if res := vk.CreateDescriptorSetLayout(
        vulkan.device,
        &descriptor_set_layout_info,
        nil,
        &descriptor_set_layout); res != .SUCCESS {
        app_panic("Fuck")
    }

    descriptor_pool_size := vk.DescriptorPoolSize {
        type = .UNIFORM_BUFFER,
        descriptorCount = u32(len(vulkan.frames)),
    }

    descriptor_pool_info := vk.DescriptorPoolCreateInfo {
        sType = .DESCRIPTOR_POOL_CREATE_INFO,
        maxSets = u32(len(vulkan.frames)),
        poolSizeCount = 1,
        pPoolSizes = &descriptor_pool_size,
    }

    descriptor_pool: vk.DescriptorPool
    if res := vk.CreateDescriptorPool(
        vulkan.device,
        &descriptor_pool_info,
        nil,
        &descriptor_pool); res != .SUCCESS {
        app_panic("Fuck2")
    }

    descriptor_set_allocate_info := vk.DescriptorSetAllocateInfo {
        sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
        descriptorPool = descriptor_pool,
        descriptorSetCount = 1,
        pSetLayouts = &descriptor_set_layout,
    }

    descriptor_sets := make([]vk.DescriptorSet, len(vulkan.frames))
    for &descriptor_set, i in descriptor_sets {
        if res := vk.AllocateDescriptorSets(
            vulkan.device,
            &descriptor_set_allocate_info,
            &descriptor_set); res != .SUCCESS {
            app_panic("Fuck3")
        }

        descriptor_buffer_info := vk.DescriptorBufferInfo {
            buffer = uniform_buffer,
            offset = 0,
            range = size_of(Uniforms),
        }

        write_descriptor_set := vk.WriteDescriptorSet {
            sType = .WRITE_DESCRIPTOR_SET,
            dstSet = descriptor_set,
            dstBinding = 0,
            descriptorCount = 1,
            descriptorType = .UNIFORM_BUFFER,
            pBufferInfo = &descriptor_buffer_info,
        }

        vk.UpdateDescriptorSets(vulkan.device, 1, &write_descriptor_set, 0, nil)
    }

    vert: vk.PipelineShaderStageCreateInfo
    if s, res := vulkan_create_shader_stage(vulkan.device, "build/debug/shader_vert.spv", .VERTEX); res != .SUCCESS {
        app_panic("Failed to create vertex shader stage.")
    } else {
        vert = s
    }

    frag: vk.PipelineShaderStageCreateInfo
    if s, res := vulkan_create_shader_stage(vulkan.device, "build/debug/shader_frag.spv", .FRAGMENT); res != .SUCCESS {
        app_panic("Failed to create fragment shader stage.")
    } else {
        frag = s
    }

    shader_stages := []vk.PipelineShaderStageCreateInfo {
        vert,
        frag,
    }

    pipeline_layout_info := vk.PipelineLayoutCreateInfo {
        sType = .PIPELINE_LAYOUT_CREATE_INFO,
        setLayoutCount = 1,
        pSetLayouts = &descriptor_set_layout,
    }

    pipeline_layout: vk.PipelineLayout
    if res := vk.CreatePipelineLayout(vulkan.device, &pipeline_layout_info, nil, &pipeline_layout); res != .SUCCESS {
        app_panic("Failed to create pipeline layout!")
    }

    pipeline: vk.Pipeline
    if p, res := vulkan_create_graphics_pipeline(&vulkan, shader_stages, pipeline_layout = pipeline_layout); res != .SUCCESS {
        app_panic("Failed to create graphics pipeline!")
    } else {
        pipeline = p
    }

    for app_update() {
        cb: vk.CommandBuffer
        if command_buffer, res := vulkan_begin_rendering_commands(&vulkan); res != .SUCCESS {
            app_panic("Unexpected failure occurred.")
        } else {
            cb = command_buffer
        }

        @static bruh := f32(0.0)
        bruh += dt

        u.model = linalg.matrix4_rotate(-bruh, Vector3{0.0, 1.0, 0.0})
        u.view = linalg.matrix4_translate(Vector3{0.0, 0.0, -3.0})
        u.proj = linalg.matrix4_perspective(π/4.0, f32(w)/f32(h), 0.1, 100.0)

        if data, res := vulkan_map_memory(&vulkan, &vulkan_allocator, staging_buffer, 0, size_of(Uniforms)); res != .SUCCESS {
            app_panic("Failed to map staging buffer memory.")
        } else {
            copy_slice(data, transmute([]byte)mem.Raw_Slice{&u, size_of(Uniforms)})
            vulkan_unmap_memory(&vulkan, &vulkan_allocator, staging_buffer)
        }

        @static staged := false

        if !staged {
            staged = true

            buffer_barriers_before := [?]vk.BufferMemoryBarrier {
                {
                    sType = .BUFFER_MEMORY_BARRIER,
                    srcAccessMask = {},
                    dstAccessMask = {.TRANSFER_READ},
                    buffer = staging_buffer,
                    offset = 0,
                    size = size_of(Uniforms)
                },
                {
                    sType = .BUFFER_MEMORY_BARRIER,
                    srcAccessMask = {},
                    dstAccessMask = {.TRANSFER_WRITE},
                    buffer = uniform_buffer,
                    offset = 0,
                    size = size_of(Uniforms),
                },
            }

            vk.CmdPipelineBarrier(
                commandBuffer = cb,
                srcStageMask = {.TOP_OF_PIPE}, dstStageMask = {.TRANSFER},
                dependencyFlags = {},
                memoryBarrierCount = 0, pMemoryBarriers = nil,
                bufferMemoryBarrierCount = u32(len(buffer_barriers_before)), pBufferMemoryBarriers = raw_data(buffer_barriers_before[:]),
                imageMemoryBarrierCount = 0, pImageMemoryBarriers = nil)

            region := vk.BufferCopy {
                srcOffset = 0,
                dstOffset = 0,
                size = size_of(Uniforms),
            }

            vk.CmdCopyBuffer(
                commandBuffer = cb,
                srcBuffer = staging_buffer,
                dstBuffer = uniform_buffer,
                regionCount = 1,
                pRegions = &region)

            buffer_barrier_after := vk.BufferMemoryBarrier {
                sType = .BUFFER_MEMORY_BARRIER,
                srcAccessMask = {.TRANSFER_WRITE},
                dstAccessMask = {.UNIFORM_READ},
                buffer = uniform_buffer,
                offset = 0,
                size = size_of(Uniforms)
            }

            vk.CmdPipelineBarrier(
                commandBuffer = cb,
                srcStageMask = {.TRANSFER}, dstStageMask = {.VERTEX_SHADER},
                dependencyFlags = {},
                memoryBarrierCount = 0, pMemoryBarriers = nil,
                bufferMemoryBarrierCount = 1, pBufferMemoryBarriers = &buffer_barrier_after,
                imageMemoryBarrierCount = 0, pImageMemoryBarriers = nil)
        } else {
            buffer_barriers_before := [?]vk.BufferMemoryBarrier {
                {
                    sType = .BUFFER_MEMORY_BARRIER,
                    srcAccessMask = {.UNIFORM_READ},
                    dstAccessMask = {.TRANSFER_WRITE},
                    buffer = uniform_buffer,
                    offset = 0,
                    size = size_of(Uniforms),
                },
            }

            vk.CmdPipelineBarrier(
                commandBuffer = cb,
                srcStageMask = {.VERTEX_SHADER}, dstStageMask = {.TRANSFER},
                dependencyFlags = {},
                memoryBarrierCount = 0, pMemoryBarriers = nil,
                bufferMemoryBarrierCount = u32(len(buffer_barriers_before)), pBufferMemoryBarriers = raw_data(buffer_barriers_before[:]),
                imageMemoryBarrierCount = 0, pImageMemoryBarriers = nil)

            region := vk.BufferCopy {
                srcOffset = 0,
                dstOffset = 0,
                size = size_of(Uniforms),
            }

            vk.CmdCopyBuffer(
                commandBuffer = cb,
                srcBuffer = staging_buffer,
                dstBuffer = uniform_buffer,
                regionCount = 1,
                pRegions = &region)

            buffer_barrier_after := vk.BufferMemoryBarrier {
                sType = .BUFFER_MEMORY_BARRIER,
                srcAccessMask = {.TRANSFER_WRITE},
                dstAccessMask = {.UNIFORM_READ},
                buffer = uniform_buffer,
                offset = 0,
                size = size_of(Uniforms)
            }

            vk.CmdPipelineBarrier(
                commandBuffer = cb,
                srcStageMask = {.TRANSFER}, dstStageMask = {.VERTEX_SHADER},
                dependencyFlags = {},
                memoryBarrierCount = 0, pMemoryBarriers = nil,
                bufferMemoryBarrierCount = 1, pBufferMemoryBarriers = &buffer_barrier_after,
                imageMemoryBarrierCount = 0, pImageMemoryBarriers = nil)
        }

        vulkan_begin_rendering(&vulkan, 0.0, 0.0, 0.0, 0.0)
        {
            vk.CmdBindPipeline(cb, .GRAPHICS, pipeline)
            vk.CmdBindDescriptorSets(cb, .GRAPHICS, pipeline_layout,
                firstSet = 0, descriptorSetCount = 1, pDescriptorSets = &descriptor_sets[vulkan.frame_idx],
                dynamicOffsetCount = 0, pDynamicOffsets = nil)
            vk.CmdDraw(commandBuffer = cb,
                vertexCount = 36, instanceCount = 1,
                firstVertex = 0, firstInstance = 0)
        }
        vulkan_end_rendering(&vulkan)

        if res := vulkan_end_rendering_commands(&vulkan); res != .SUCCESS {
            app_panic("Unexpected failure occurred.")
        }

        free_all(context.temp_allocator)
    }
}