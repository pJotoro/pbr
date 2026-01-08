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
    physical_device_memory_properties: vk.PhysicalDeviceMemoryProperties,
    physical_device_properties: vk.PhysicalDeviceProperties2,
    physical_device_vulkan_11_properties: vk.PhysicalDeviceVulkan11Properties,
    physical_device_features: vk.PhysicalDeviceFeatures2,
    physical_device_vulkan_11_features: vk.PhysicalDeviceVulkan11Features,

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
    image_idx: u32,

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

    default_vertex_input_state: vk.PipelineVertexInputStateCreateInfo,

    default_input_assembly_state: vk.PipelineInputAssemblyStateCreateInfo,
    
    default_viewport: vk.Viewport,
    default_scissor: vk.Rect2D,
    default_viewport_state: vk.PipelineViewportStateCreateInfo,
    
    default_rasterization_state: vk.PipelineRasterizationStateCreateInfo,

    default_multisample_state: vk.PipelineMultisampleStateCreateInfo,

    default_color_blend_attachment_state: vk.PipelineColorBlendAttachmentState,
    default_color_blend_state: vk.PipelineColorBlendStateCreateInfo,

    default_dynamic_state: vk.PipelineDynamicStateCreateInfo,

    default_pipeline_info: vk.GraphicsPipelineCreateInfo,
}

vulkan_init :: proc(using vulkan: ^Vulkan, minimum_version, desired_version: u32) -> vk.Result {
    {
        did_load: bool
        if lib, did_load = dynlib.load_library(VULKAN_LIB_NAME); !did_load {
            return .ERROR_INCOMPATIBLE_DRIVER 
        }
    }
    {
        vkGetInstanceProcAddr := dynlib.symbol_address(lib, "vkGetInstanceProcAddr")
        vk.load_proc_addresses_global(vkGetInstanceProcAddr)
    }
    
    api_version: u32
    if desired_version == vk.API_VERSION_1_0 {
        api_version = vk.API_VERSION_1_0
    } else {
        if (vk.EnumerateInstanceVersion == nil) {
            if minimum_version > vk.API_VERSION_1_0 {
                return .ERROR_INCOMPATIBLE_DRIVER
            } else {
                api_version = vk.API_VERSION_1_0
            }
        } else {
            vk.EnumerateInstanceVersion(&api_version) or_return
            if api_version < minimum_version {
                return .ERROR_INCOMPATIBLE_DRIVER
            }
            if api_version > desired_version {
                api_version = desired_version
            }
        }
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
        instance_layer_properties = make([]vk.LayerProperties, instance_layer_count, arena)
        vk.EnumerateInstanceLayerProperties(&instance_layer_count, raw_data(instance_layer_properties)) or_return

        for layer in instance_layers {
            found := false
            for &props in instance_layer_properties {
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
        instance_extension_properties = make([]vk.ExtensionProperties, instance_extension_count, arena)
        
        cur_instance_extension_properties := instance_extension_properties
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
        instance_extension_properties = make([]vk.ExtensionProperties, instance_extension_count, arena)
        vk.EnumerateInstanceExtensionProperties(nil, &instance_extension_count, raw_data(instance_extension_properties)) or_return
    }

    for extension in instance_extensions {
        found := false
        for &props in instance_extension_properties {
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
            apiVersion = api_version,
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
                pUserData = vulkan,
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

        vk.CreateInstance(&create_info, nil, &instance) or_return
        vk.load_proc_addresses_instance(instance)
    }

    {
        count := u32(16)
        physical_devices_array: [16]vk.PhysicalDevice
        vk.EnumeratePhysicalDevices(instance, &count, raw_data(physical_devices_array[:])) or_return
        physical_devices := physical_devices_array[0:int(count)]

        #reverse for pd in physical_devices {
            properties: vk.PhysicalDeviceProperties
            vk.GetPhysicalDeviceProperties(pd, &properties)
            if (properties.deviceType == .DISCRETE_GPU) {
                physical_device = pd
                break
            }
        }
    }

    physical_device_properties.sType = .PHYSICAL_DEVICE_PROPERTIES_2
    physical_device_properties.pNext = &physical_device_vulkan_11_properties
    physical_device_vulkan_11_properties.sType = .PHYSICAL_DEVICE_VULKAN_1_1_PROPERTIES
    vk.GetPhysicalDeviceProperties2(physical_device, &physical_device_properties)

    vk.GetPhysicalDeviceMemoryProperties(physical_device, &physical_device_memory_properties)

    physical_device_features.sType = .PHYSICAL_DEVICE_FEATURES_2
    physical_device_features.pNext = &physical_device_vulkan_11_features
    physical_device_vulkan_11_features.sType = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES
    vk.GetPhysicalDeviceFeatures2(physical_device, &physical_device_features)

    physical_device_features.features.robustBufferAccess = false
    physical_device_features.features.fullDrawIndexUint32 = false
    physical_device_features.features.imageCubeArray = false
    physical_device_features.features.independentBlend = false
    physical_device_features.features.geometryShader = false
    physical_device_features.features.tessellationShader = false
    physical_device_features.features.sampleRateShading = false
    physical_device_features.features.dualSrcBlend = false
    physical_device_features.features.logicOp = false
    physical_device_features.features.multiDrawIndirect = false
    physical_device_features.features.drawIndirectFirstInstance = false
    physical_device_features.features.depthClamp = false
    physical_device_features.features.depthBiasClamp = false
    physical_device_features.features.fillModeNonSolid = false
    physical_device_features.features.depthBounds = false
    physical_device_features.features.wideLines = false
    physical_device_features.features.largePoints = false
    physical_device_features.features.alphaToOne = false
    physical_device_features.features.multiViewport = false
    physical_device_features.features.samplerAnisotropy = false
    physical_device_features.features.textureCompressionETC2 = false
    physical_device_features.features.textureCompressionASTC_LDR = false
    physical_device_features.features.textureCompressionBC = false
    physical_device_features.features.occlusionQueryPrecise = false
    physical_device_features.features.pipelineStatisticsQuery = false
    physical_device_features.features.vertexPipelineStoresAndAtomics = false
    physical_device_features.features.fragmentStoresAndAtomics = false
    physical_device_features.features.shaderTessellationAndGeometryPointSize = false
    physical_device_features.features.shaderImageGatherExtended = false
    physical_device_features.features.shaderStorageImageExtendedFormats = false
    physical_device_features.features.shaderStorageImageMultisample = false
    physical_device_features.features.shaderStorageImageReadWithoutFormat = false
    physical_device_features.features.shaderStorageImageWriteWithoutFormat = false
    physical_device_features.features.shaderUniformBufferArrayDynamicIndexing = false
    physical_device_features.features.shaderSampledImageArrayDynamicIndexing = false
    physical_device_features.features.shaderStorageBufferArrayDynamicIndexing = false
    physical_device_features.features.shaderStorageImageArrayDynamicIndexing = false
    physical_device_features.features.shaderClipDistance = false
    physical_device_features.features.shaderCullDistance = false
    physical_device_features.features.shaderFloat64 = false
    physical_device_features.features.shaderInt64 = false
    physical_device_features.features.shaderInt16 = false
    physical_device_features.features.shaderResourceResidency = false
    physical_device_features.features.shaderResourceMinLod = false
    physical_device_features.features.sparseBinding = false
    physical_device_features.features.sparseResidencyBuffer = false
    physical_device_features.features.sparseResidencyImage2D = false
    physical_device_features.features.sparseResidencyImage3D = false
    physical_device_features.features.sparseResidency2Samples = false
    physical_device_features.features.sparseResidency4Samples = false
    physical_device_features.features.sparseResidency8Samples = false
    physical_device_features.features.sparseResidency16Samples = false
    physical_device_features.features.sparseResidencyAliased = false
    physical_device_features.features.variableMultisampleRate = false
    physical_device_features.features.inheritedQueries = false

    physical_device_vulkan_11_features.storageBuffer16BitAccess = false
    physical_device_vulkan_11_features.uniformAndStorageBuffer16BitAccess = false
    physical_device_vulkan_11_features.storagePushConstant16 = false
    physical_device_vulkan_11_features.storageInputOutput16 = false
    physical_device_vulkan_11_features.multiview = false
    physical_device_vulkan_11_features.multiviewGeometryShader = false
    physical_device_vulkan_11_features.multiviewTessellationShader = false
    physical_device_vulkan_11_features.variablePointersStorageBuffer = false
    physical_device_vulkan_11_features.variablePointers = false
    physical_device_vulkan_11_features.protectedMemory = false
    physical_device_vulkan_11_features.samplerYcbcrConversion = false
    physical_device_vulkan_11_features.shaderDrawParameters = false

    {
        count: u32
        vk.GetPhysicalDeviceQueueFamilyProperties(physical_device, &count, nil)
        queue_family_properties = make([]vk.QueueFamilyProperties, count, arena)
        vk.GetPhysicalDeviceQueueFamilyProperties(physical_device, &count, raw_data(queue_family_properties))
    }

    surface = vulkan_create_surface(vulkan) or_return
    vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface, &surface_capabilities) or_return
    {
        count: u32
        vk.GetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &count, nil) or_return
        surface_formats = make([]vk.SurfaceFormatKHR, count, arena)
        vk.GetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &count, raw_data(surface_formats)) or_return
    }

    // TODO: Find out if there have been any papers written about queue family properties.
    queue_priorities := [32]f32 {
        1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0,
        1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0,
        1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0,
        1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0,
    }

    queue_infos := make([dynamic]vk.DeviceQueueCreateInfo, 0, len(queue_family_properties), context.temp_allocator)
    queue_count := 0
    for props, queue_family_idx in queue_family_properties {
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

    vk.CreateDevice(physical_device, &{
        sType = .DEVICE_CREATE_INFO,
        pNext = &physical_device_features,
        queueCreateInfoCount = u32(len(queue_infos)),
        pQueueCreateInfos = raw_data(queue_infos),
        enabledExtensionCount = u32(len(device_extensions)),
        ppEnabledExtensionNames = raw_data(device_extensions[:]),
    }, nil, &device) or_return
    vk.load_proc_addresses_device(device)

    queues = make([]vk.Queue, queue_count, arena)
    queue_array_idx := 0
    for props, queue_family_idx in queue_family_properties {
        for queue_idx in 0..<int(props.queueCount) {
            vk.GetDeviceQueue(device, u32(queue_family_idx), u32(queue_idx), &queues[queue_array_idx])
            queue_array_idx += 1
        }
    }

    // TODO
    graphics_queue = queues[0]
    present_queue = queues[0]

    swapchain_format = surface_formats[0] // TODO
    swapchain_extent = surface_capabilities.currentExtent
    vk.CreateSwapchainKHR(device, &{
        sType = .SWAPCHAIN_CREATE_INFO_KHR,
        surface = surface,
        minImageCount = surface_capabilities.minImageCount, // TODO
        imageFormat = swapchain_format.format,
        imageColorSpace = swapchain_format.colorSpace,
        imageExtent = swapchain_extent,
        imageArrayLayers = 1,
        imageUsage = {.COLOR_ATTACHMENT},
        preTransform = surface_capabilities.currentTransform,
        compositeAlpha = {.OPAQUE},
        presentMode = .FIFO, // TODO
        clipped = true,
    }, nil, &swapchain) or_return

    {
        count: u32
        vk.GetSwapchainImagesKHR(device, swapchain, &count, nil) or_return
        swapchain_images = make([]vk.Image, count, arena)
        vk.GetSwapchainImagesKHR(device, swapchain, &count, raw_data(swapchain_images)) or_return
    }

    swapchain_image_views = make([]vk.ImageView, len(swapchain_images), arena)
    for &swapchain_image_view, idx in swapchain_image_views {
        vk.CreateImageView(device, &{
            sType = .IMAGE_VIEW_CREATE_INFO,
            image = swapchain_images[idx],
            viewType = .D2,
            format = swapchain_format.format,
            subresourceRange = {
                aspectMask = {.COLOR}, 
                levelCount = 1, 
                layerCount = 1
            },
        }, nil, &swapchain_image_view) or_return
    }
    frames = make([]Vulkan_Frame, len(swapchain_images), arena)

    {
        color_attachment := vk.AttachmentDescription {
            format = swapchain_format.format,
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

        vk.CreateRenderPass(device, &info, nil, &render_pass) or_return
    }

    vk.CreateCommandPool(device, &{
        sType = .COMMAND_POOL_CREATE_INFO,
        flags = {.TRANSIENT, .RESET_COMMAND_BUFFER},

        // TODO:
        // queueFamilyIndex = 0,
    }, nil, &command_pool) or_return

    command_buffers := make([]vk.CommandBuffer, len(frames), context.temp_allocator)
    vk.AllocateCommandBuffers(
        device, 
        &{ sType = .COMMAND_BUFFER_ALLOCATE_INFO, commandPool = command_pool, commandBufferCount = u32(len(frames))}, 
        raw_data(command_buffers)) or_return
    for &frame, idx in frames {
        frame.command_buffer = command_buffers[idx]
    }

    for &frame in frames {
        vk.CreateFence(device, &{sType = .FENCE_CREATE_INFO, flags = {.SIGNALED} }, nil, &frame.fence_in_flight) or_return
    }

    for &frame in frames {
        vk.CreateSemaphore(device, &{sType = .SEMAPHORE_CREATE_INFO}, nil, &frame.sem_image_available) or_return
        vk.CreateSemaphore(device, &{sType = .SEMAPHORE_CREATE_INFO}, nil, &frame.sem_render_finished) or_return
    }

    swapchain_framebuffers = make([]vk.Framebuffer, len(swapchain_images), arena)
    for idx in 0..<len(swapchain_images) {
        attachments := [?]vk.ImageView {
            swapchain_image_views[idx],
        }

        info := vk.FramebufferCreateInfo {
            sType = .FRAMEBUFFER_CREATE_INFO,
            renderPass = render_pass,
            attachmentCount = u32(len(attachments)),
            pAttachments = raw_data(attachments[:]),
            width = swapchain_extent.width,
            height = swapchain_extent.height,
            layers = 1,
        }
        vk.CreateFramebuffer(device, &info, nil, &swapchain_framebuffers[idx]) or_return
    }

    vk.CreateSampler(device, &{sType = .SAMPLER_CREATE_INFO}, nil, &default_sampler) or_return

    vk.CreatePipelineLayout(device, &{sType = .PIPELINE_LAYOUT_CREATE_INFO}, nil, &default_pipeline_layout) or_return
    vk.CreatePipelineCache(device, &{sType = .PIPELINE_CACHE_CREATE_INFO}, nil, &default_pipeline_cache) or_return

    default_vertex_input_state = vk.PipelineVertexInputStateCreateInfo {
        sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    }

    default_input_assembly_state = vk.PipelineInputAssemblyStateCreateInfo {
        sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        topology = .TRIANGLE_LIST,
    }

    default_viewport = vk.Viewport {
        width = f32(swapchain_extent.width),
        height = f32(swapchain_extent.height),
        maxDepth = 1.0,
    }
    default_scissor = vk.Rect2D {
        extent = swapchain_extent,
    }
    default_viewport_state = vk.PipelineViewportStateCreateInfo {
        sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        viewportCount = 1,
        pViewports = &default_viewport,
        scissorCount = 1,
        pScissors = &default_scissor,
    }

    default_rasterization_state = vk.PipelineRasterizationStateCreateInfo {
        sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        polygonMode = .FILL,
        cullMode = {.BACK},
        frontFace = .COUNTER_CLOCKWISE,
        lineWidth = 1.0,
    }

    default_multisample_state = vk.PipelineMultisampleStateCreateInfo {
        sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        rasterizationSamples = {._1},
    }

    default_color_blend_attachment_state = vk.PipelineColorBlendAttachmentState {
        colorWriteMask = {.R, .G, .B, .A},
    }
    default_color_blend_state = vk.PipelineColorBlendStateCreateInfo {
        sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        attachmentCount = 1,
        pAttachments = &default_color_blend_attachment_state,
    }

    default_dynamic_state = vk.PipelineDynamicStateCreateInfo {
        sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    }

    default_pipeline_info = vk.GraphicsPipelineCreateInfo {
        sType = .GRAPHICS_PIPELINE_CREATE_INFO,
        flags = {},
        pInputAssemblyState = &default_input_assembly_state,
        pViewportState = &default_viewport_state,
        pRasterizationState = &default_rasterization_state,
        pMultisampleState = &default_multisample_state,
        pColorBlendState = &default_color_blend_state,
        pDynamicState = &default_dynamic_state,
        layout = default_pipeline_layout,
        renderPass = render_pass,
    }
    when VULKAN_DISABLE_PIPELINE_OPTIMIZATION {
        default_pipeline_info.flags += {.DISABLE_OPTIMIZATION}
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

vulkan_create_graphics_pipeline :: proc(
    using vulkan: ^Vulkan, 
    
    shader_stages: []vk.PipelineShaderStageCreateInfo, 
    
    vertex_input_state:     ^vk.PipelineVertexInputStateCreateInfo      = nil,
    input_assembly_state:   ^vk.PipelineInputAssemblyStateCreateInfo    = nil,
    viewport_state:         ^vk.PipelineViewportStateCreateInfo         = nil,
    rasterization_state:    ^vk.PipelineRasterizationStateCreateInfo    = nil,
    multisample_state:      ^vk.PipelineMultisampleStateCreateInfo      = nil,
    color_blend_state:      ^vk.PipelineColorBlendStateCreateInfo       = nil,
    dynamic_state:          ^vk.PipelineDynamicStateCreateInfo          = nil,
    
    pipeline_layout: vk.PipelineLayout = {}) -> (pipeline: vk.Pipeline, res: vk.Result) 
{
    pipeline_info := default_pipeline_info

    pipeline_info.stageCount = u32(len(shader_stages))
    pipeline_info.pStages = raw_data(shader_stages)

    pipeline_info.pVertexInputState = vertex_input_state if vertex_input_state != nil else &default_vertex_input_state
    pipeline_info.pInputAssemblyState = input_assembly_state if input_assembly_state != nil else &default_input_assembly_state
    pipeline_info.pViewportState = viewport_state if viewport_state != nil else &default_viewport_state
    pipeline_info.pRasterizationState = rasterization_state if rasterization_state != nil else &default_rasterization_state
    pipeline_info.pMultisampleState = multisample_state if multisample_state != nil else &default_multisample_state
    pipeline_info.pColorBlendState = color_blend_state if color_blend_state != nil else &default_color_blend_state
    pipeline_info.pDynamicState = dynamic_state if dynamic_state != nil else &default_dynamic_state

    pipeline_info.layout = pipeline_layout if pipeline_layout != {} else default_pipeline_layout

    res = vk.CreateGraphicsPipelines(device, default_pipeline_cache, 1, &pipeline_info, nil, &pipeline)
    return
}

// TODO: vulkan_create_graphics_pipelines

vulkan_begin_rendering_commands :: proc(using vulkan: ^Vulkan) -> (cb: vk.CommandBuffer, res: vk.Result) {
    vk.WaitForFences(device, 1, &frames[frame_idx].fence_in_flight, true, max(u64)) or_return
    vk.ResetFences(device, 1, &frames[frame_idx].fence_in_flight) or_return

    vk.AcquireNextImageKHR(device, swapchain, max(u64), frames[frame_idx].sem_image_available, vk.Fence{}, &image_idx) or_return

    if image_idx == 0 {
        @static app_ready := -1
        if app_ready == -1 {
            app_ready += 1
        } else if app_ready == 0 {
            app_ready += 1
            app_show()
        }
    }

    cb = frames[frame_idx].command_buffer
    vk.BeginCommandBuffer(cb, &{
        sType = .COMMAND_BUFFER_BEGIN_INFO,
        flags = {.ONE_TIME_SUBMIT},
    }) or_return

    return
}

vulkan_end_rendering_commands :: proc(using vulkan: ^Vulkan) -> vk.Result {
    cb := frames[frame_idx].command_buffer
    vk.EndCommandBuffer(cb) or_return

    wait_stage := vk.PipelineStageFlags{.COLOR_ATTACHMENT_OUTPUT}
    submit_info := vk.SubmitInfo {
        sType = .SUBMIT_INFO,
        waitSemaphoreCount = 1,
        pWaitSemaphores = &frames[frame_idx].sem_image_available,
        pWaitDstStageMask = &wait_stage,
        commandBufferCount = 1,
        pCommandBuffers = &cb,
        signalSemaphoreCount = 1,
        pSignalSemaphores = &frames[frame_idx].sem_render_finished,
    }
    vk.QueueSubmit(graphics_queue, 1, &submit_info, frames[frame_idx].fence_in_flight) or_return

    present_info := vk.PresentInfoKHR {
        sType = .PRESENT_INFO_KHR,
        waitSemaphoreCount = 1,
        pWaitSemaphores = &frames[frame_idx].sem_render_finished,
        swapchainCount = 1,
        pSwapchains = &swapchain,
        pImageIndices = &image_idx,
    }
    vk.QueuePresentKHR(graphics_queue, &present_info) or_return

    frame_idx = (frame_idx + 1) % len(frames)

    return .SUCCESS
}

vulkan_begin_rendering :: proc(using vulkan: ^Vulkan, r, g, b, a: f32) {
    vk.CmdBeginRenderPass(frames[frame_idx].command_buffer, &{
        sType = .RENDER_PASS_BEGIN_INFO,
        renderPass = render_pass,
        framebuffer = swapchain_framebuffers[int(image_idx)],
        renderArea = { extent = swapchain_extent },
        clearValueCount = 1,
        pClearValues = &vk.ClearValue {
            color = {
                float32 = {r, g, b, a},
            },
        },
    }, .INLINE)
}

vulkan_end_rendering :: proc(using vulkan: ^Vulkan) {
    vk.CmdEndRenderPass(frames[frame_idx].command_buffer)
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
    if res := vulkan_init(&vulkan, vk.API_VERSION_1_1, vk.API_VERSION_1_1); res != .SUCCESS {
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

    pipeline: vk.Pipeline
    if p, res := vulkan_create_graphics_pipeline(&vulkan, shader_stages); res != .SUCCESS {
        app_panic("Failed to create graphics pipeline!")
    } else {
        pipeline = p
    }

    Uniforms :: struct {
        model: matrix[4, 4]f32,
        view: matrix[4, 4]f32,
        projection: matrix[4, 4]f32,
    }

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

    for app_update() {
        cb: vk.CommandBuffer
        if command_buffer, res := vulkan_begin_rendering_commands(&vulkan); res != .SUCCESS {
            app_panic("Unexpected failure occurred.")
        } else {
            cb = command_buffer
        }

        vulkan_begin_rendering(&vulkan, 0.0, 0.0, 0.0, 0.0)
        {
            vk.CmdBindPipeline(cb, .GRAPHICS, pipeline)
            vk.CmdDraw(commandBuffer = cb,
                vertexCount = 3, instanceCount = 1,
                firstVertex = 0, firstInstance = 0)
        }
        vulkan_end_rendering(&vulkan)

        if res := vulkan_end_rendering_commands(&vulkan); res != .SUCCESS {
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
