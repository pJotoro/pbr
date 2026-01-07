package pbr

import "base:intrinsics"
import "base:runtime"
import "core:dynlib"
import "core:mem"
import vk "vendor:vulkan"
import "core:debug/trace"
// import "vendor:cgltf"
// import "core:os"
// import "core:fmt"

VULKAN_DEBUG :: #config(VULKAN_DEBUG, ODIN_DEBUG)
VULKAN_VALIDATION :: #config(VULKAN_VALIDATION, VULKAN_DEBUG)
VULKAN_DEBUG_UTILS :: #config(VULKAN_DEBUG_UTILS, VULKAN_DEBUG)
VULKAN_LAYERS :: #config(VULKAN_LAYERS, VULKAN_DEBUG)
VULKAN_DISABLE_PIPELINE_OPTIMIZATION :: #config(VULKAN_DISABLE_PIPELINE_OPTIMIZATION, VULKAN_DEBUG)

STACK_TRACE :: #config(STACK_TRACE, ODIN_DEBUG)

Vulkan_Frame :: struct {
    command_buffer: vk.CommandBuffer,
    sem_image_available: vk.Semaphore,
    sem_render_finished: vk.Semaphore,
    fence_in_flight: vk.Fence,
}

Vulkan :: struct {
    arena: mem.Allocator,

    lib: dynlib.Library,

    instance: vk.Instance,
    instance_layer_properties: []vk.LayerProperties,
    instance_extension_properties: []vk.ExtensionProperties,

    physical_device: vk.PhysicalDevice,
    physical_device_properties: vk.PhysicalDeviceProperties,
    physical_device_memory_properties: vk.PhysicalDeviceMemoryProperties,
    physical_device_features: vk.PhysicalDeviceFeatures,

    surface: vk.SurfaceKHR,
    surface_capabilities: vk.SurfaceCapabilitiesKHR,
    surface_formats: []vk.SurfaceFormatKHR,

    device: vk.Device,
    device_extension_properties: []vk.ExtensionProperties,
    
    queue_family_properties: []vk.QueueFamilyProperties,
    queues: []vk.Queue,
    graphics_queue: vk.Queue,
    present_queue: vk.Queue,

    swapchain: vk.SwapchainKHR,
    swapchain_images: []vk.Image,
    swapchain_image_views: []vk.ImageView,
    swapchain_format: vk.SurfaceFormatKHR,
    swapchain_extent: vk.Extent2D,
    swapchain_framebuffers: []vk.Framebuffer,

    render_pass: vk.RenderPass,

    command_pool: vk.CommandPool,

    frames: []Vulkan_Frame,
    frame_idx: int,

    // vertex_buffer, index_buffer, staging_buffer: Vulkan_Buffer,
    // vertex_buffer_regions: [dynamic]vk.BufferCopy,
    // index_buffer_regions: [dynamic]vk.BufferCopy,

    default_sampler: vk.Sampler,

    default_pipeline_layout: vk.PipelineLayout,
    default_pipeline_cache: vk.PipelineCache,

    default_input_assembly_info: vk.PipelineInputAssemblyStateCreateInfo,
    
    default_viewport: vk.Viewport,
    default_scissor: vk.Rect2D,
    default_viewport_info: vk.PipelineViewportStateCreateInfo,
    
    default_rasterization_info: vk.PipelineRasterizationStateCreateInfo,

    default_multisample_info: vk.PipelineMultisampleStateCreateInfo,

    default_color_blend_attachment_info: vk.PipelineColorBlendAttachmentState,
    default_color_blend_info: vk.PipelineColorBlendStateCreateInfo,

    default_dynamic_state_info: vk.PipelineDynamicStateCreateInfo,

    default_pipeline_info: vk.GraphicsPipelineCreateInfo,

    staged: bool,
    image_idx: u32,
}

vulkan_init :: proc(ctx: ^Vulkan) -> vk.Result {
    {
        did_load: bool
        if ctx.lib, did_load = dynlib.load_library(VULKAN_LIB_NAME); !did_load {
            return .ERROR_INCOMPATIBLE_DRIVER 
        }
    }
    {
        vkGetInstanceProcAddr := dynlib.symbol_address(ctx.lib, "vkGetInstanceProcAddr")
        vk.load_proc_addresses_global(vkGetInstanceProcAddr)
    }

    when VULKAN_LAYERS {
        instance_layers := [?]cstring {
            "VK_LAYER_KHRONOS_validation", 
            "VK_LAYER_LUNARG_monitor",
        }
    }

    instance_extensions := make([dynamic]cstring, 0, 4, context.temp_allocator)
    append(&instance_extensions, cstring("VK_KHR_surface"), VK_KHR_platform_surface)
    when VULKAN_DEBUG_UTILS {
        append(&instance_extensions, "VK_EXT_debug_utils")
    }
    when VULKAN_LAYERS {
        append(&instance_extensions, "VK_EXT_layer_settings")
    }

    when VULKAN_LAYERS {
        instance_layer_count: u32
        vk.EnumerateInstanceLayerProperties(&instance_layer_count, nil) or_return
        ctx.instance_layer_properties = make([]vk.LayerProperties, instance_layer_count, ctx.arena)
        vk.EnumerateInstanceLayerProperties(&instance_layer_count, raw_data(ctx.instance_layer_properties)) or_return

        for layer in instance_layers {
            found := false
            for &props in ctx.instance_layer_properties {
                if layer == cstring(raw_data(props.layerName[:])) {
                    found = true
                    break
                }
            }
            if !found {
                return .ERROR_LAYER_NOT_PRESENT
            }
        }
    }

    when VULKAN_LAYERS {
        instance_extension_count: u32
        vk.EnumerateInstanceExtensionProperties(nil, &instance_extension_count, nil) or_return
        for instance_layer in instance_layers {
            count: u32
            vk.EnumerateInstanceExtensionProperties(instance_layer, &count, nil) or_return
            instance_extension_count += count

        }
        ctx.instance_extension_properties = make([]vk.ExtensionProperties, instance_extension_count, ctx.arena)
        
        cur_instance_extension_properties := ctx.instance_extension_properties
        {
            count := u32(len(cur_instance_extension_properties))
            vk.EnumerateInstanceExtensionProperties(nil, &count, raw_data(cur_instance_extension_properties)) or_return
            cur_instance_extension_properties = cur_instance_extension_properties[int(count):]
        }
        for instance_layer in instance_layers {
            count := u32(len(cur_instance_extension_properties))
            vk.EnumerateInstanceExtensionProperties(instance_layer, &count, raw_data(cur_instance_extension_properties)) or_return
            cur_instance_extension_properties = cur_instance_extension_properties[int(count):]
        }
    } else {
        instance_extension_count: u32
        vk.EnumerateInstanceExtensionProperties(nil, &instance_extension_count, nil) or_return
        ctx.instance_extension_properties = make([]vk.ExtensionProperties, instance_extension_count, ctx.arena)
        vk.EnumerateInstanceExtensionProperties(nil, &instance_extension_count, raw_data(ctx.instance_extension_properties)) or_return
    }

    for extension in instance_extensions {
        found := false
        for &props in ctx.instance_extension_properties {
            if extension == cstring(raw_data(props.extensionName[:])) {
                found = true
                break
            }
        }
        if !found {
            return .ERROR_EXTENSION_NOT_PRESENT
        }
    }

    {
        app_info := vk.ApplicationInfo {
            sType = .APPLICATION_INFO,
            pApplicationName = "pbr",
            applicationVersion = vk.API_VERSION_1_0,
            pEngineName = "pbr",
            engineVersion = vk.API_VERSION_1_0,
            apiVersion = vk.API_VERSION_1_0,
        }

        create_info := vk.InstanceCreateInfo {
            sType = .INSTANCE_CREATE_INFO,
            pApplicationInfo = &app_info,
            enabledExtensionCount = u32(len(instance_extensions)),
            ppEnabledExtensionNames = raw_data(instance_extensions),
        }

        when VULKAN_DEBUG_UTILS {
            debug_info := vk.DebugUtilsMessengerCreateInfoEXT {
                sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
                messageSeverity = {.VERBOSE, .ERROR, .WARNING, .INFO},
                messageType = {.GENERAL, .PERFORMANCE},
                pfnUserCallback = vulkan_debug_callback,
                pUserData = ctx,
            }
            when VULKAN_VALIDATION {
                debug_info.messageType += {.VALIDATION}
            }
        }

        when VULKAN_LAYERS {
            create_info.enabledLayerCount = u32(len(instance_layers))
            create_info.ppEnabledLayerNames = raw_data(instance_layers[:])
        }

        when VULKAN_VALIDATION {
            validation_enabled := [?]vk.ValidationFeatureEnableEXT {
                .BEST_PRACTICES,
                .SYNCHRONIZATION_VALIDATION,
            }
            validation_info := vk.ValidationFeaturesEXT {
                sType = .VALIDATION_FEATURES_EXT,
                enabledValidationFeatureCount = u32(len(validation_enabled)),
                pEnabledValidationFeatures = raw_data(validation_enabled[:]),
            }
        }

        when VULKAN_DEBUG_UTILS && VULKAN_VALIDATION {
            create_info.pNext = &debug_info
            debug_info.pNext = &validation_info
        } else when VULKAN_DEBUG_UTILS {
            create_info.pNext = &debug_info
        } else when VULKAN_VALIDATION {
            create_info.pNext = &validation_info
        }

        vk.CreateInstance(&create_info, nil, &ctx.instance) or_return
        vk.load_proc_addresses_instance(ctx.instance)
    }

    {
        count := u32(16)
        physical_devices_array: [16]vk.PhysicalDevice
        vk.EnumeratePhysicalDevices(ctx.instance, &count, raw_data(physical_devices_array[:])) or_return
        physical_devices := physical_devices_array[0:int(count)]

        #reverse for pd in physical_devices {
            vk.GetPhysicalDeviceProperties(pd, &ctx.physical_device_properties)
            if (ctx.physical_device_properties.deviceType == .DISCRETE_GPU) {
                ctx.physical_device = pd
                break
            }
        }
    }

    vk.GetPhysicalDeviceMemoryProperties(ctx.physical_device, &ctx.physical_device_memory_properties)
    vk.GetPhysicalDeviceFeatures(ctx.physical_device, &ctx.physical_device_features)

    ctx.physical_device_features.robustBufferAccess = false
    ctx.physical_device_features.fullDrawIndexUint32 = false
    ctx.physical_device_features.imageCubeArray = false
    ctx.physical_device_features.independentBlend = false
    ctx.physical_device_features.geometryShader = false
    ctx.physical_device_features.tessellationShader = false
    ctx.physical_device_features.sampleRateShading = false
    ctx.physical_device_features.dualSrcBlend = false
    ctx.physical_device_features.logicOp = false
    ctx.physical_device_features.multiDrawIndirect = false
    ctx.physical_device_features.drawIndirectFirstInstance = false
    ctx.physical_device_features.depthClamp = false
    ctx.physical_device_features.depthBiasClamp = false
    ctx.physical_device_features.fillModeNonSolid = false
    ctx.physical_device_features.depthBounds = false
    ctx.physical_device_features.wideLines = false
    ctx.physical_device_features.largePoints = false
    ctx.physical_device_features.alphaToOne = false
    ctx.physical_device_features.multiViewport = false
    ctx.physical_device_features.samplerAnisotropy = false
    ctx.physical_device_features.textureCompressionETC2 = false
    ctx.physical_device_features.textureCompressionASTC_LDR = false
    ctx.physical_device_features.textureCompressionBC = false
    ctx.physical_device_features.occlusionQueryPrecise = false
    ctx.physical_device_features.pipelineStatisticsQuery = false
    ctx.physical_device_features.vertexPipelineStoresAndAtomics = false
    ctx.physical_device_features.fragmentStoresAndAtomics = false
    ctx.physical_device_features.shaderTessellationAndGeometryPointSize = false
    ctx.physical_device_features.shaderImageGatherExtended = false
    ctx.physical_device_features.shaderStorageImageExtendedFormats = false
    ctx.physical_device_features.shaderStorageImageMultisample = false
    ctx.physical_device_features.shaderStorageImageReadWithoutFormat = false
    ctx.physical_device_features.shaderStorageImageWriteWithoutFormat = false
    ctx.physical_device_features.shaderUniformBufferArrayDynamicIndexing = false
    ctx.physical_device_features.shaderSampledImageArrayDynamicIndexing = false
    ctx.physical_device_features.shaderStorageBufferArrayDynamicIndexing = false
    ctx.physical_device_features.shaderStorageImageArrayDynamicIndexing = false
    ctx.physical_device_features.shaderClipDistance = false
    ctx.physical_device_features.shaderCullDistance = false
    ctx.physical_device_features.shaderFloat64 = false
    ctx.physical_device_features.shaderInt64 = false
    ctx.physical_device_features.shaderInt16 = false
    ctx.physical_device_features.shaderResourceResidency = false
    ctx.physical_device_features.shaderResourceMinLod = false
    ctx.physical_device_features.sparseBinding = false
    ctx.physical_device_features.sparseResidencyBuffer = false
    ctx.physical_device_features.sparseResidencyImage2D = false
    ctx.physical_device_features.sparseResidencyImage3D = false
    ctx.physical_device_features.sparseResidency2Samples = false
    ctx.physical_device_features.sparseResidency4Samples = false
    ctx.physical_device_features.sparseResidency8Samples = false
    ctx.physical_device_features.sparseResidency16Samples = false
    ctx.physical_device_features.sparseResidencyAliased = false
    ctx.physical_device_features.variableMultisampleRate = false
    ctx.physical_device_features.inheritedQueries = false

    {
        count: u32
        vk.GetPhysicalDeviceQueueFamilyProperties(ctx.physical_device, &count, nil)
        ctx.queue_family_properties = make([]vk.QueueFamilyProperties, count, ctx.arena)
        vk.GetPhysicalDeviceQueueFamilyProperties(ctx.physical_device, &count, raw_data(ctx.queue_family_properties))
    }

    ctx.surface = vulkan_create_surface(ctx) or_return
    vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(ctx.physical_device, ctx.surface, &ctx.surface_capabilities) or_return
    {
        count: u32
        vk.GetPhysicalDeviceSurfaceFormatsKHR(ctx.physical_device, ctx.surface, &count, nil) or_return
        ctx.surface_formats = make([]vk.SurfaceFormatKHR, count, ctx.arena)
        vk.GetPhysicalDeviceSurfaceFormatsKHR(ctx.physical_device, ctx.surface, &count, raw_data(ctx.surface_formats)) or_return
    }

    // TODO: Find out if there have been any papers written about queue family properties.
    queue_priorities := [32]f32 {
        1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0,
        1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0,
        1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0,
        1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0,
    }

    queue_infos := make([dynamic]vk.DeviceQueueCreateInfo, 0, len(ctx.queue_family_properties), context.temp_allocator)
    queue_count := 0
    for props, queue_family_idx in ctx.queue_family_properties {
        if props.queueCount > 0 {
            append(&queue_infos, vk.DeviceQueueCreateInfo{
                sType = .DEVICE_QUEUE_CREATE_INFO,
                queueFamilyIndex = u32(queue_family_idx),
                queueCount = props.queueCount,
                pQueuePriorities = raw_data(queue_priorities[:]),
            })
            queue_count += int(props.queueCount)
        }
    }

    device_extensions := [?]cstring {
        "VK_KHR_swapchain",
    }

    vk.CreateDevice(ctx.physical_device, &{
        sType = .DEVICE_CREATE_INFO,
        queueCreateInfoCount = u32(len(queue_infos)),
        pQueueCreateInfos = raw_data(queue_infos),
        enabledExtensionCount = u32(len(device_extensions)),
        ppEnabledExtensionNames = raw_data(device_extensions[:]),
        pEnabledFeatures = &ctx.physical_device_features,
    }, nil, &ctx.device) or_return
    vk.load_proc_addresses_device(ctx.device)

    ctx.queues = make([]vk.Queue, queue_count, ctx.arena)
    queue_array_idx := 0
    for props, queue_family_idx in ctx.queue_family_properties {
        for queue_idx in 0..<int(props.queueCount) {
            vk.GetDeviceQueue(ctx.device, u32(queue_family_idx), u32(queue_idx), &ctx.queues[queue_array_idx])
            queue_array_idx += 1
        }
    }

    // TODO
    ctx.graphics_queue = ctx.queues[0]
    ctx.present_queue = ctx.queues[0]

    ctx.swapchain_format = ctx.surface_formats[0] // TODO
    ctx.swapchain_extent = ctx.surface_capabilities.currentExtent
    vk.CreateSwapchainKHR(ctx.device, &{
        sType = .SWAPCHAIN_CREATE_INFO_KHR,
        surface = ctx.surface,
        minImageCount = ctx.surface_capabilities.minImageCount, // TODO
        imageFormat = ctx.swapchain_format.format,
        imageColorSpace = ctx.swapchain_format.colorSpace,
        imageExtent = ctx.swapchain_extent,
        imageArrayLayers = 1,
        imageUsage = {.COLOR_ATTACHMENT},
        preTransform = ctx.surface_capabilities.currentTransform,
        compositeAlpha = {.OPAQUE},
        presentMode = .FIFO, // TODO
        clipped = true,
    }, nil, &ctx.swapchain) or_return

    {
        count: u32
        vk.GetSwapchainImagesKHR(ctx.device, ctx.swapchain, &count, nil) or_return
        ctx.swapchain_images = make([]vk.Image, count, ctx.arena)
        vk.GetSwapchainImagesKHR(ctx.device, ctx.swapchain, &count, raw_data(ctx.swapchain_images)) or_return
    }

    ctx.swapchain_image_views = make([]vk.ImageView, len(ctx.swapchain_images), ctx.arena)
    for &swapchain_image_view, idx in ctx.swapchain_image_views {
        vk.CreateImageView(ctx.device, &{
            sType = .IMAGE_VIEW_CREATE_INFO,
            image = ctx.swapchain_images[idx],
            viewType = .D2,
            format = ctx.swapchain_format.format,
            subresourceRange = {
                aspectMask = {.COLOR}, 
                levelCount = 1, 
                layerCount = 1
            },
        }, nil, &swapchain_image_view) or_return
    }
    ctx.frames = make([]Vulkan_Frame, len(ctx.swapchain_images), ctx.arena)

    {
        color_attachment := vk.AttachmentDescription {
            format = ctx.swapchain_format.format,
            samples = {._1},
            loadOp = .CLEAR,
            storeOp = .STORE,
            stencilLoadOp = .DONT_CARE,
            stencilStoreOp = .DONT_CARE,
            initialLayout = .UNDEFINED,
            finalLayout = .PRESENT_SRC_KHR,
        }

        color_attachment_ref := vk.AttachmentReference {
            attachment = 0,
            layout = .COLOR_ATTACHMENT_OPTIMAL,
        }

        subpass := vk.SubpassDescription {
            pipelineBindPoint = .GRAPHICS,
            colorAttachmentCount = 1,
            pColorAttachments = &color_attachment_ref,
        }

        subpass_dependency := vk.SubpassDependency {
            srcSubpass = vk.SUBPASS_EXTERNAL,
            dstSubpass = 0,
            srcStageMask = {.COLOR_ATTACHMENT_OUTPUT},
            dstStageMask = {.COLOR_ATTACHMENT_OUTPUT},
            srcAccessMask = {},
            dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
        }

        attachments := [?]vk.AttachmentDescription { 
            color_attachment,
        }

        info := vk.RenderPassCreateInfo {
            sType = .RENDER_PASS_CREATE_INFO,
            attachmentCount = u32(len(attachments)),
            pAttachments = raw_data(attachments[:]),
            subpassCount = 1,
            pSubpasses = &subpass,
            dependencyCount = 1,
            pDependencies = &subpass_dependency,
        }

        vk.CreateRenderPass(ctx.device, &info, nil, &ctx.render_pass) or_return
    }

    vk.CreateCommandPool(ctx.device, &{
        sType = .COMMAND_POOL_CREATE_INFO,
        flags = {.TRANSIENT, .RESET_COMMAND_BUFFER},

        // TODO:
        // queueFamilyIndex = 0,
    }, nil, &ctx.command_pool) or_return

    command_buffers := make([]vk.CommandBuffer, len(ctx.frames), context.temp_allocator)
    vk.AllocateCommandBuffers(
        ctx.device, 
        &{ sType = .COMMAND_BUFFER_ALLOCATE_INFO, commandPool = ctx.command_pool, commandBufferCount = u32(len(ctx.frames))}, 
        raw_data(command_buffers)) or_return
    for &frame, idx in ctx.frames {
        frame.command_buffer = command_buffers[idx]
    }

    for &frame in ctx.frames {
        vk.CreateFence(ctx.device, &{sType = .FENCE_CREATE_INFO, flags = {.SIGNALED} }, nil, &frame.fence_in_flight) or_return
    }

    for &frame in ctx.frames {
        vk.CreateSemaphore(ctx.device, &{sType = .SEMAPHORE_CREATE_INFO}, nil, &frame.sem_image_available) or_return
        vk.CreateSemaphore(ctx.device, &{sType = .SEMAPHORE_CREATE_INFO}, nil, &frame.sem_render_finished) or_return
    }

    ctx.swapchain_framebuffers = make([]vk.Framebuffer, len(ctx.swapchain_images), ctx.arena)
    for idx in 0..<len(ctx.swapchain_images) {
        attachments := [?]vk.ImageView {
            ctx.swapchain_image_views[idx],
        }

        info := vk.FramebufferCreateInfo {
            sType = .FRAMEBUFFER_CREATE_INFO,
            renderPass = ctx.render_pass,
            attachmentCount = u32(len(attachments)),
            pAttachments = raw_data(attachments[:]),
            width = ctx.swapchain_extent.width,
            height = ctx.swapchain_extent.height,
            layers = 1,
        }
        vk.CreateFramebuffer(ctx.device, &info, nil, &ctx.swapchain_framebuffers[idx]) or_return
    }

    vk.CreateSampler(ctx.device, &{sType = .SAMPLER_CREATE_INFO}, nil, &ctx.default_sampler) or_return

    vk.CreatePipelineLayout(ctx.device, &{sType = .PIPELINE_LAYOUT_CREATE_INFO}, nil, &ctx.default_pipeline_layout) or_return
    vk.CreatePipelineCache(ctx.device, &{sType = .PIPELINE_CACHE_CREATE_INFO}, nil, &ctx.default_pipeline_cache) or_return

    ctx.default_input_assembly_info = vk.PipelineInputAssemblyStateCreateInfo {
        sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        topology = .TRIANGLE_LIST,
    }

    ctx.default_viewport = vk.Viewport {
        width = f32(ctx.swapchain_extent.width),
        height = f32(ctx.swapchain_extent.height),
        maxDepth = 1.0,
    }
    ctx.default_scissor = vk.Rect2D {
        extent = ctx.swapchain_extent,
    }
    ctx.default_viewport_info = vk.PipelineViewportStateCreateInfo {
        sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        viewportCount = 1,
        pViewports = &ctx.default_viewport,
        scissorCount = 1,
        pScissors = &ctx.default_scissor,
    }

    ctx.default_rasterization_info = vk.PipelineRasterizationStateCreateInfo {
        sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        polygonMode = .FILL,
        cullMode = {.BACK},
        frontFace = .COUNTER_CLOCKWISE,
        lineWidth = 1.0,
    }

    ctx.default_multisample_info = vk.PipelineMultisampleStateCreateInfo {
        sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        rasterizationSamples = {._1},
    }

    ctx.default_color_blend_attachment_info = vk.PipelineColorBlendAttachmentState {
        colorWriteMask = {.R, .G, .B, .A},
    }
    ctx.default_color_blend_info = vk.PipelineColorBlendStateCreateInfo {
        sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        attachmentCount = 1,
        pAttachments = &ctx.default_color_blend_attachment_info,
    }

    ctx.default_dynamic_state_info = vk.PipelineDynamicStateCreateInfo {
        sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    }

    ctx.default_pipeline_info = vk.GraphicsPipelineCreateInfo {
        sType = .GRAPHICS_PIPELINE_CREATE_INFO,
        flags = {},
        pInputAssemblyState = &ctx.default_input_assembly_info,
        pViewportState = &ctx.default_viewport_info,
        pRasterizationState = &ctx.default_rasterization_info,
        pMultisampleState = &ctx.default_multisample_info,
        pColorBlendState = &ctx.default_color_blend_info,
        pDynamicState = &ctx.default_dynamic_state_info,
        layout = ctx.default_pipeline_layout,
        renderPass = ctx.render_pass,
    }
    when VULKAN_DISABLE_PIPELINE_OPTIMIZATION {
        ctx.default_pipeline_info.flags += {.DISABLE_OPTIMIZATION}
    }
        
    /*
    Parts of gltf file I don't handle yet that I have to:

    meshes
    materials
    accessors
    nodes
    extensions    
    */

    // vertex_buffer_create_info := vk.BufferCreateInfo {
    //     sType = .BUFFER_CREATE_INFO,
    //     usage = {.TRANSFER_DST, .VERTEX_BUFFER},
    // }
    // index_buffer_create_info := vk.BufferCreateInfo {
    //     sType = .BUFFER_CREATE_INFO,
    //     usage = {.TRANSFER_DST, .INDEX_BUFFER},
    // }
    // staging_buffer_create_info := vk.BufferCreateInfo {
    //     sType = .BUFFER_CREATE_INFO,
    //     usage = {.TRANSFER_SRC},
    // }


    // if data, res := cgltf_load("assets/chocolate_donut.glb"); res != .success {
    //     app_panic("Failed to load assets/chocolate_donut.glb")
    // } else {
        // vertex_inputs := make([dynamic]vk.PipelineVertexInputStateCreateInfo, 0, len(data.meshes), context.temp_allocator)
        // for mesh in data.meshes {
        //     attributes := make([dynamic]vk.VertexInputAttributeDescription, 0, len(mesh.primitives), context.temp_allocator)
        //     bindings := make([dynamic]vk.VertexInputBindingDescription, 0, len(mesh.primitives), context.temp_allocator)
        //     for primitive, location in mesh.primitives {
        //         attribute := vk.VertexInputAttributeDescription {
        //             location = u32(location),

        //         }
        //     }
        //     vertex_input := vk.PipelineVertexInputStateCreateInfo {
        //         sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        //     }
        // }

        // for mesh in data.meshes {
        //     // mesh.name
        //     // mesh.primitives
        //     assert(mesh.weights == nil)
        //     assert(mesh.target_names == nil)
        //     assert(mesh.extras.data == nil)
        //     assert(mesh.extensions_count == 0)

        //     attributes: [dynamic]vk.VertexInputAttributeDescription
        //     for primitive, binding_index in mesh.primitives {
        //         assert(primitive.type == .triangles)
        //         assert(primitive.indices.component_type == .r_16u)
        //         assert(!primitive.indices.normalized)
        //         assert(primitive.indices.type == .scalar)
        //         assert(primitive.indices.offset == 0)
        //         assert(primitive.indices.count == 6 || primitive.indices.count == 36)
        //         assert(primitive.indices.stride == 2)
        //         // primitive.buffer_view
        //         assert(!primitive.indices.has_min)
        //         assert(!primitive.indices.has_max)
        //         assert(!primitive.indices.is_sparse)
        //         assert(primitive.indices.extras.data == nil)
        //         assert(primitive.indices.extensions_count == 0)
        //         // primitive.material
        //         // primitive.attributes
        //         for attribute, attribute_index in primitive.attributes {
        //             append(&attributes, vk.VertexInputAttributeDescription{
        //                 location = u32(attribute_index),
        //                 binding = u32(binding_index),
        //                 //format = 
        //             })
        //         }
        //         assert(primitive.targets == nil)
        //         assert(primitive.extras.data == nil)
        //         assert(!primitive.has_draco_mesh_compression)
        //         assert(primitive.mappings == nil)
        //         assert(primitive.extensions_count == 0)

        //         fmt.printf("%#v\n", primitive)
        //     }
        // }

        // vertex_buffer_offset := 0
        // index_buffer_offset := 0

        // for buffer_view in data.buffer_views {
        //     assert(buffer_view.stride == 0 && buffer_view.data == nil && !buffer_view.has_meshopt_compression && buffer_view.extras.data == nil && buffer_view.extensions_count == 0)

        //     switch buffer_view.type {
        //         case .vertices:
        //             vertex_buffer_create_info.size += vk.DeviceSize(buffer_view.size)
        //             append(&vertex_buffer_regions, vk.BufferCopy{
        //                 srcOffset = vk.DeviceSize(buffer_view.offset),
        //                 dstOffset = vk.DeviceSize(vertex_buffer_offset),
        //                 size = vk.DeviceSize(buffer_view.size),
        //             })

        //         case .indices:
        //             index_buffer_create_info.size += vk.DeviceSize(buffer_view.size)
        //             append(&index_buffer_regions, vk.BufferCopy{
        //                 srcOffset = vk.DeviceSize(buffer_view.offset),
        //                 dstOffset = vk.DeviceSize(index_buffer_offset),
        //                 size = vk.DeviceSize(buffer_view.size),
        //             })

        //         case .invalid:
        //             app_panic("Invalid buffer view type.")
        //     }
        // }

    //     vertex_buffer = vulkan_create_buffer(device, &physical_device_memory_properties, &vertex_buffer_create_info, {.DEVICE_LOCAL}) or_return
    //     index_buffer = vulkan_create_buffer(device, &physical_device_memory_properties, &index_buffer_create_info, {.DEVICE_LOCAL}) or_return
    //     staging_buffer_create_info.size = vertex_buffer_create_info.size + index_buffer_create_info.size
    //     staging_buffer = vulkan_create_buffer(device, &physical_device_memory_properties, &staging_buffer_create_info, {.HOST_VISIBLE, .HOST_COHERENT}) or_return

    //     // NOTE: This happens to be true for the donut model. It might not be true for other models.
    //     assert(int(staging_buffer_create_info.size) == len(data.bin))

    //     m: rawptr
    //     vk.MapMemory(device, staging_buffer.memory, 0, staging_buffer_create_info.size, {}, &m) or_return
    //     intrinsics.mem_copy(m, raw_data(data.bin), staging_buffer_create_info.size)
    //     vk.UnmapMemory(device, staging_buffer.memory)
    // }

    return .SUCCESS
}

vulkan_create_graphics_pipeline_with_defaults :: proc(ctx: ^Vulkan, shader_stages: []vk.PipelineShaderStageCreateInfo, vertex_input: ^vk.PipelineVertexInputStateCreateInfo) -> (pipeline: vk.Pipeline, res: vk.Result) {
    pipeline_info := ctx.default_pipeline_info
    pipeline_info.stageCount = u32(len(shader_stages))
    pipeline_info.pStages = raw_data(shader_stages)
    pipeline_info.pVertexInputState = vertex_input

    res = vk.CreateGraphicsPipelines(ctx.device, ctx.default_pipeline_cache, 1, &pipeline_info, nil, &pipeline)
    return
}

vulkan_create_graphics_pipeline :: proc {vulkan_create_graphics_pipeline_with_defaults}

// TODO: vulkan_create_graphics_pipelines

// vulkan_get_format_from_cgltf_component_type_and_cgltf_type :: #force_inline proc "contextless" (cgltf_component_type: cgltf.component_type, cgltf_type: cgltf.type) -> vk.Format {
//     #partial switch cgltf_component_type {
//         case .r_8:
//             #partial switch cgltf_type {
//                 case .scalar:
//                     return .R8_SINT
//                 case .vec2:
//                     return .R8G8_SINT
//                 case .vec3:
//                     return .R8G8B8_SINT
//                 case .vec4:
//                     return .R8G8B8A8_SINT
//             }
//         case .r_8u:
//             #partial switch cgltf_type {
//                 case .scalar:
//                     return .R8_UINT
//                 case .vec2:
//                     return .R8G8_UINT
//                 case .vec3:
//                     return .R8G8B8_UINT
//                 case .vec4:
//                     return .R8G8B8A8_UINT
//             }
//         case .r_16:
//             #partial switch cgltf_type {
//                 case .scalar:
//                     return .R16_SINT
//                 case .vec2:
//                     return .R16G16_SINT
//                 case .vec3:
//                     return .R16G16B16_SINT
//                 case .vec4:
//                     return .R16G16B16A16_SINT
//             }
//         case .r_16u:
//             #partial switch cgltf_type {
//                 case .scalar:
//                     return .R16_UINT
//                 case .vec2:
//                     return .R16G16_UINT
//                 case .vec3:
//                     return .R16G16B16_UINT
//                 case .vec4:
//                     return .R16G16B16A16_UINT
//             }
//         case .r_32u:
//             #partial switch cgltf_type {
//                 case .scalar:
//                     return .R32_UINT
//                 case .vec2:
//                     return .R32G32_UINT
//                 case .vec3:
//                     return .R32G32B32_UINT
//                 case .vec4:
//                     return .R32G32B32A32_UINT
//             }
//         case .r_32f:
//             #partial switch cgltf_type {
//                 case .scalar:
//                     return .R32_SFLOAT
//                 case .vec2:
//                     return .R32G32_SFLOAT
//                 case .vec3:
//                     return .R32G32B32_SFLOAT
//                 case .vec4:
//                     return .R32G32B32A32_SFLOAT
//             }
//     }

//     return .UNDEFINED
// }

// vulkan_get_format :: proc{vulkan_get_format_from_cgltf_component_type_and_cgltf_type}

vulkan_begin_frame :: proc(ctx: ^Vulkan) -> (cb: vk.CommandBuffer, res: vk.Result) {
    vk.WaitForFences(ctx.device, 1, &ctx.frames[ctx.frame_idx].fence_in_flight, true, max(u64)) or_return
    vk.ResetFences(ctx.device, 1, &ctx.frames[ctx.frame_idx].fence_in_flight) or_return

    vk.AcquireNextImageKHR(ctx.device, ctx.swapchain, max(u64), ctx.frames[ctx.frame_idx].sem_image_available, vk.Fence{}, &ctx.image_idx) or_return

    if ctx.image_idx == 0 {
        @static app_ready := -1
        if app_ready == -1 {
            app_ready += 1
        } else if app_ready == 0 {
            app_ready += 1
            app_show()
        }
    }

    cb = ctx.frames[ctx.frame_idx].command_buffer
    vk.BeginCommandBuffer(cb, &{
        sType = .COMMAND_BUFFER_BEGIN_INFO,
        flags = {.ONE_TIME_SUBMIT},
    }) or_return

    return
}

vulkan_end_frame :: proc(ctx: ^Vulkan) -> vk.Result {
    cb := ctx.frames[ctx.frame_idx].command_buffer
    vk.EndCommandBuffer(cb) or_return

    wait_stage := vk.PipelineStageFlags{.COLOR_ATTACHMENT_OUTPUT}
    submit_info := vk.SubmitInfo {
        sType = .SUBMIT_INFO,
        waitSemaphoreCount = 1,
        pWaitSemaphores = &ctx.frames[ctx.frame_idx].sem_image_available,
        pWaitDstStageMask = &wait_stage,
        commandBufferCount = 1,
        pCommandBuffers = &cb,
        signalSemaphoreCount = 1,
        pSignalSemaphores = &ctx.frames[ctx.frame_idx].sem_render_finished,
    }
    vk.QueueSubmit(ctx.graphics_queue, 1, &submit_info, ctx.frames[ctx.frame_idx].fence_in_flight) or_return

    present_info := vk.PresentInfoKHR {
        sType = .PRESENT_INFO_KHR,
        waitSemaphoreCount = 1,
        pWaitSemaphores = &ctx.frames[ctx.frame_idx].sem_render_finished,
        swapchainCount = 1,
        pSwapchains = &ctx.swapchain,
        pImageIndices = &ctx.image_idx,
    }
    vk.QueuePresentKHR(ctx.graphics_queue, &present_info) or_return

    ctx.frame_idx = (ctx.frame_idx + 1) % len(ctx.frames)

    return .SUCCESS
}

// cgltf_load :: proc(name: string) -> (out_data: ^cgltf.data, res: cgltf.result) {
//     file_data, ok := os.read_entire_file(name, context.temp_allocator)
//     if !ok {
//         res = .file_not_found
//         return
//     }

//     alloc_proc :: proc "c" (user: rawptr, size: uint) -> rawptr {
//         context = runtime.default_context()
//         data := make([]byte, size, context.temp_allocator)
//         return raw_data(data)
//     }

//     free_proc :: proc "c" (user: rawptr, ptr: rawptr) {

//     }

//     memory_options := cgltf.memory_options {
//         alloc_func = alloc_proc,
//         free_func = free_proc,
//         user_data = nil,
//     }

//     options := cgltf.options {
//         type = .glb,
//         memory = memory_options,
//     }

//     return cgltf.parse(options, raw_data(file_data), len(file_data))
// }

Vulkan_Buffer :: struct {
    handle: vk.Buffer,
    memory: vk.DeviceMemory,
    offset: vk.DeviceSize,
}

vulkan_create_buffer :: proc(device: vk.Device, memory_properties: ^vk.PhysicalDeviceMemoryProperties, create_info: ^vk.BufferCreateInfo, memory_property_flags: vk.MemoryPropertyFlags) -> (buffer: Vulkan_Buffer, res: vk.Result) {
    vk.CreateBuffer(device, create_info, nil, &buffer.handle) or_return

    memory_requirements: vk.MemoryRequirements
    vk.GetBufferMemoryRequirements(device, buffer.handle, &memory_requirements)

    memory_type_idx := -1
    memory_types := memory_properties.memoryTypes[0:int(memory_properties.memoryTypeCount)]
    for memory_type, idx in memory_types {
        if memory_property_flags <= memory_type.propertyFlags {
            memory_type_idx = idx
            break
        }
    }
    assert(memory_type_idx != -1)

    allocate_info := vk.MemoryAllocateInfo {
        sType = .MEMORY_ALLOCATE_INFO,
        allocationSize = memory_requirements.size,
        memoryTypeIndex = u32(memory_type_idx),
    }
    vk.AllocateMemory(device, &allocate_info, nil, &buffer.memory) or_return

    return
}

main :: proc() {
    when STACK_TRACE {
        trace.init(&global_trace_ctx)
        context.assertion_failure_proc = debug_trace_assertion_failure_proc
    }

    w, h, refresh_rate := app_init()
    dt := 1.0/f32(refresh_rate)

    vulkan: Vulkan
    vulkan.arena = mem.arena_allocator(&{data = make([]byte, mem.Megabyte)})
    if res := vulkan_init(&vulkan); res != .SUCCESS {
        app_panic("Your graphics driver is out of date.")
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
    vertex_input := vk.PipelineVertexInputStateCreateInfo {
        sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    }

    pipeline: vk.Pipeline
    if p, res := vulkan_create_graphics_pipeline(&vulkan, shader_stages, &vertex_input); res != .SUCCESS {
        app_panic("Failed to create graphics pipeline!")
    } else {
        pipeline = p
    }

    for app_update() {
        cb: vk.CommandBuffer
        if command_buffer, res := vulkan_begin_frame(&vulkan); res != .SUCCESS {
            app_panic("Unexpected failure occurred.")
        } else {
            cb = command_buffer
        }

        vk.CmdBeginRenderPass(cb, &{
            sType = .RENDER_PASS_BEGIN_INFO,
            renderPass = vulkan.render_pass,
            framebuffer = vulkan.swapchain_framebuffers[int(vulkan.image_idx)],
            renderArea = { extent = vulkan.swapchain_extent },
            clearValueCount = 1,
            pClearValues = &vk.ClearValue {
                color = {
                    float32 = {0.0, 0.0, 0.0, 0.0},
                },
            },
        }, .INLINE)

        vk.CmdBindPipeline(cb, .GRAPHICS, pipeline)
        vk.CmdDraw(commandBuffer = cb,
            vertexCount = 3, instanceCount = 1,
            firstVertex = 0, firstInstance = 0)

        vk.CmdEndRenderPass(cb)

        if res := vulkan_end_frame(&vulkan); res != .SUCCESS {
            app_panic("Unexpected failure occurred.")
        }

        free_all(context.temp_allocator)
    }
}

vulkan_create_shader_stage :: proc(device: vk.Device, $path: string, stage: vk.ShaderStageFlag) -> (shader_stage: vk.PipelineShaderStageCreateInfo, res: vk.Result) {
    shader_stage.sType = .PIPELINE_SHADER_STAGE_CREATE_INFO
    shader_stage.stage = {stage}
    shader_stage.pName = "main"

    file_data := #load(path, []u32)

    info := vk.ShaderModuleCreateInfo { 
        sType = .SHADER_MODULE_CREATE_INFO,
        codeSize = len(file_data)*size_of(u32),
        pCode = raw_data(file_data),
    }
    vk.CreateShaderModule(device, &info, nil, &shader_stage.module) or_return

    return
}

vulkan_destroy_shader_stage :: proc(device: vk.Device, shader_stage: vk.PipelineShaderStageCreateInfo) {
    vk.DestroyShaderModule(device, shader_stage.module, nil)
}

when VULKAN_DEBUG_UTILS {
    vulkan_debug_callback :: proc "system" (severity: vk.DebugUtilsMessageSeverityFlagsEXT, types: vk.DebugUtilsMessageTypeFlagsEXT, data: ^vk.DebugUtilsMessengerCallbackDataEXT, user_data: rawptr) -> b32
    {
        runtime.print_string(string(data.pMessage))
        runtime.print_byte('\n')
        return false
    }
}

when STACK_TRACE {
    global_trace_ctx: trace.Context

    debug_trace_assertion_failure_proc :: proc(prefix, message: string, loc := #caller_location) -> ! {
        runtime.print_caller_location(loc)
        runtime.print_string(" ")
        runtime.print_string(prefix)
        if len(message) > 0 {
            runtime.print_string(": ")
            runtime.print_string(message)
        }
        runtime.print_byte('\n')

        ctx := &global_trace_ctx
        if !trace.in_resolve(ctx) {
            buf: [64]trace.Frame
            runtime.print_string("Debug Trace:\n")
            frames := trace.frames(ctx, 1, buf[:])
            for f, i in frames {
                fl := trace.resolve(ctx, f, context.temp_allocator)
                if fl.loc.file_path == "" && fl.loc.line == 0 {
                    continue
                }
                runtime.print_caller_location(fl.loc)
                runtime.print_string(" - frame ")
                runtime.print_int(i)
                runtime.print_byte('\n')
            }
        }
        runtime.trap()
    }
}