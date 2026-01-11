package pbr

import "core:mem"
import "core:math/linalg"

import vk "vendor:vulkan"

Cube_Uniforms :: struct {
    model: matrix[4, 4]f32,
    view: matrix[4, 4]f32,
    proj: matrix[4, 4]f32,
}

Cube :: struct {
    u: Cube_Uniforms,
    pipeline: vk.Pipeline,
    pipeline_layout: vk.PipelineLayout,
    descriptor_set: vk.DescriptorSet,
    staging_buffer, uniform_buffer: vk.Buffer,
}

cube_init :: proc(vulkan: ^Vulkan, vulkan_allocator: ^Vulkan_Allocator, using cube: ^Cube) -> vk.Result {

    uniform_buffer = vulkan_create_buffer(vulkan, vulkan_allocator, 
        size_of(Cube_Uniforms), {.TRANSFER_DST, .UNIFORM_BUFFER}, {.DEVICE_LOCAL}, {.HOST_VISIBLE}) or_return

    staging_buffer = vulkan_create_buffer(vulkan, vulkan_allocator, 
        size_of(Cube_Uniforms), {.TRANSFER_SRC}, {.HOST_VISIBLE, .HOST_COHERENT}, {.DEVICE_LOCAL}) or_return

    vulkan_alloc(vulkan, vulkan_allocator) or_return

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
    vk.CreateDescriptorSetLayout(
        vulkan.device,
        &descriptor_set_layout_info,
        nil,
        &descriptor_set_layout) or_return

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
    vk.CreateDescriptorPool(
        vulkan.device,
        &descriptor_pool_info,
        nil,
        &descriptor_pool) or_return

    descriptor_set_allocate_info := vk.DescriptorSetAllocateInfo {
        sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
        descriptorPool = descriptor_pool,
        descriptorSetCount = 1,
        pSetLayouts = &descriptor_set_layout,
    }

    vk.AllocateDescriptorSets(
        vulkan.device,
        &descriptor_set_allocate_info,
        &descriptor_set) or_return

    descriptor_buffer_info := vk.DescriptorBufferInfo {
        buffer = uniform_buffer,
        offset = 0,
        range = size_of(Cube_Uniforms),
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

    pipeline_layout_info := vk.PipelineLayoutCreateInfo {
        sType = .PIPELINE_LAYOUT_CREATE_INFO,
        setLayoutCount = 1,
        pSetLayouts = &descriptor_set_layout,
    }

    vk.CreatePipelineLayout(vulkan.device, &pipeline_layout_info, nil, &pipeline_layout) or_return

    {
        vert := vulkan_create_shader_stage(vulkan.device, "build/debug/shader_vert.spv", .VERTEX) or_return
        defer vulkan_destroy_shader_stage(vulkan.device, vert)

        frag := vulkan_create_shader_stage(vulkan.device, "build/debug/shader_frag.spv", .FRAGMENT) or_return
        defer vulkan_destroy_shader_stage(vulkan.device, frag)

        shader_stages := []vk.PipelineShaderStageCreateInfo {
            vert,
            frag,
        }

        pipeline = vulkan_create_graphics_pipeline(vulkan, shader_stages, pipeline_layout = pipeline_layout) or_return
    }

    return .SUCCESS
}

cube_update :: proc(vulkan: ^Vulkan, vulkan_allocator: ^Vulkan_Allocator, using cube: ^Cube, aspect: f32, dt: f32) -> vk.Result {
    @static bruh := f32(0.0)
    bruh += dt

    u.model = linalg.matrix4_rotate(-bruh, Vector3{0.0, 1.0, 0.0})
    u.view = linalg.matrix4_translate(Vector3{0.0, 0.0, -3.0})
    u.proj = linalg.matrix4_perspective(π/4.0, aspect, 0.1, 100.0)

    data := vulkan_map_memory_buffer(vulkan, vulkan_allocator, staging_buffer, 0, size_of(Cube_Uniforms)) or_return
    copy_slice(data, transmute([]byte)mem.Raw_Slice{&u, size_of(Cube_Uniforms)})
    vulkan_unmap_memory(vulkan, vulkan_allocator, staging_buffer)

    return .SUCCESS
}

cube_barriers :: proc(cb: vk.CommandBuffer, using cube: ^Cube) {
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
                size = size_of(Cube_Uniforms)
            },
            {
                sType = .BUFFER_MEMORY_BARRIER,
                srcAccessMask = {},
                dstAccessMask = {.TRANSFER_WRITE},
                buffer = uniform_buffer,
                offset = 0,
                size = size_of(Cube_Uniforms),
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
            size = size_of(Cube_Uniforms),
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
            size = size_of(Cube_Uniforms)
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
                size = size_of(Cube_Uniforms),
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
            size = size_of(Cube_Uniforms),
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
            size = size_of(Cube_Uniforms)
        }

        vk.CmdPipelineBarrier(
            commandBuffer = cb,
            srcStageMask = {.TRANSFER}, dstStageMask = {.VERTEX_SHADER},
            dependencyFlags = {},
            memoryBarrierCount = 0, pMemoryBarriers = nil,
            bufferMemoryBarrierCount = 1, pBufferMemoryBarriers = &buffer_barrier_after,
            imageMemoryBarrierCount = 0, pImageMemoryBarriers = nil)
    }
}

cube_draw :: proc(cb: vk.CommandBuffer, using cube: ^Cube) {
    vk.CmdBindPipeline(cb, .GRAPHICS, pipeline)
    vk.CmdBindDescriptorSets(cb, .GRAPHICS, pipeline_layout,
        firstSet = 0, descriptorSetCount = 1, pDescriptorSets = &descriptor_set,
        dynamicOffsetCount = 0, pDynamicOffsets = nil)
    vk.CmdDraw(commandBuffer = cb,
        vertexCount = 36, instanceCount = 1,
        firstVertex = 0, firstInstance = 0)
}