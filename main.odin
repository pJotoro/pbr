package pbr

import "base:intrinsics"
import "base:runtime"

import "core:dynlib"
import "core:mem"
import "core:fmt"
import "core:math/linalg"
import "core:slice"
import "core:os"

import vk "vendor:vulkan"
import "vendor:cgltf"

APP_TOPMOST :: #config(APP_TOPMOST, !ODIN_DEBUG)

VULKAN_DEBUG :: #config(VULKAN_DEBUG, ODIN_DEBUG)
VULKAN_VALIDATION :: #config(VULKAN_VALIDATION, VULKAN_DEBUG)
VULKAN_DEBUG_UTILS :: #config(VULKAN_DEBUG_UTILS, VULKAN_DEBUG)
VULKAN_LAYERS :: #config(VULKAN_LAYERS, VULKAN_DEBUG)
VULKAN_DISABLE_PIPELINE_OPTIMIZATION :: #config(VULKAN_DISABLE_PIPELINE_OPTIMIZATION, VULKAN_DEBUG)

VULKAN_DESIRED_VERSION :: vk.API_VERSION_1_1
VULKAN_MINIMUM_VERSION :: vk.API_VERSION_1_1

π :: linalg.π

Vector2 :: linalg.Vector2f32
Vector3 :: linalg.Vector3f32
Vector4 :: linalg.Vector4f32

when VULKAN_DEBUG_UTILS {
    vulkan_debug_callback :: proc "system" (severity: vk.DebugUtilsMessageSeverityFlagsEXT, types: vk.DebugUtilsMessageTypeFlagsEXT, data: ^vk.DebugUtilsMessengerCallbackDataEXT, user_data: rawptr) -> b32
    {
        dprint_cstring(data.pMessage)
        return false
    }
}

vulkan_get_format :: proc {
    vulkan_get_format_from_cgltf_component_type_and_cgltf_type,
}

VULKAN_CHECK :: #force_inline proc(res: vk.Result, loc := #caller_location) {
    assert(res == .SUCCESS, loc=loc)
}

CHECK :: proc {
    VULKAN_CHECK,
}

vulkan_create_shader_stage :: proc(device: vk.Device, $path: string, stage: vk.ShaderStageFlag) -> (shader_stage: vk.PipelineShaderStageCreateInfo) {
    shader_stage.sType = .PIPELINE_SHADER_STAGE_CREATE_INFO
    shader_stage.stage = {stage}
    shader_stage.pName = "main"

    file_data := #load(path, []u32)

    info := vk.ShaderModuleCreateInfo { 
        sType = .SHADER_MODULE_CREATE_INFO,
        codeSize = len(file_data)*size_of(u32),
        pCode = raw_data(file_data),
    }
    CHECK(vk.CreateShaderModule(device, &info, nil, &shader_stage.module))

    return
}

vulkan_destroy_shader_stage :: proc(device: vk.Device, shader_stage: vk.PipelineShaderStageCreateInfo) {
    vk.DestroyShaderModule(device, shader_stage.module, nil)
}

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
    instance_extensions: [dynamic]cstring,

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
    device_extensions: [dynamic]cstring,
    
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

    pipeline_cache: vk.PipelineCache,
}


main :: proc() {
    context.assertion_failure_proc = assertion_failure_proc

    w, h, refresh_rate := app_init()
    dt := 1.0/f32(refresh_rate)

    vulkan: Vulkan
    if data, err := make([]byte, mem.Megabyte); err != .None {
        panic("Out of memory.")
    } else {
        vulkan.arena = mem.arena_allocator(&{data = data})
    }
    
    {
        did_load: bool
        if vulkan.lib, did_load = dynlib.load_library(VULKAN_LIB_NAME); !did_load {
            panic("Your system does not support Vulkan.")
        }
    }
    {
        vkGetInstanceProcAddr := dynlib.symbol_address(vulkan.lib, "vkGetInstanceProcAddr")
        vk.load_proc_addresses_global(vkGetInstanceProcAddr)
    }

    api_version_to_string :: #force_inline proc "contextless" (api_version: u32) -> string {
        switch api_version {
            case vk.API_VERSION_1_0:
                return "1.0"
            case vk.API_VERSION_1_1:
                return "1.1"
            case vk.API_VERSION_1_2:
                return "1.2"
            case vk.API_VERSION_1_3:
                return "1.3"
            case vk.API_VERSION_1_4:
                return "1.4"
        }
        return ""
    }
    
    api_version: u32
    when VULKAN_DESIRED_VERSION == vk.API_VERSION_1_0 {
        api_version = vk.API_VERSION_1_0
    } else {
        if (vk.EnumerateInstanceVersion == nil) {
            when VULKAN_MINIMUM_VERSION > vk.API_VERSION_1_0 {
                fmt.panicf("Your system only supports Vulkan 1.0, but at least Vulkan %v is required.", api_version_to_string(VULKAN_MINIMUM_VERSION))
            } else {
                api_version = vk.API_VERSION_1_0
            }
        } else {
            CHECK(vk.EnumerateInstanceVersion(&api_version))
            if api_version < VULKAN_MINIMUM_VERSION {
                fmt.panicf("Your system only supports Vulkan %v, but at least Vulkan %v is required.", 
                    api_version_to_string(api_version), api_version_to_string(VULKAN_MINIMUM_VERSION))
            } else if api_version > VULKAN_DESIRED_VERSION {
                api_version = VULKAN_DESIRED_VERSION
            }
        }
    }

    when VULKAN_LAYERS {
        instance_layers := [?]cstring {
            "VK_LAYER_KHRONOS_validation", 
            "VK_LAYER_LUNARG_monitor",
        }
    }

    when VULKAN_LAYERS {
        instance_layer_count: u32
        CHECK(vk.EnumerateInstanceLayerProperties(&instance_layer_count, nil))
        vulkan.instance_layer_properties = make([]vk.LayerProperties, instance_layer_count, vulkan.arena)
        CHECK(vk.EnumerateInstanceLayerProperties(&instance_layer_count, raw_data(vulkan.instance_layer_properties)))

        for layer in instance_layers {
            found := false
            for &props in vulkan.instance_layer_properties {
                if layer == cstring(raw_data(props.layerName[:])) {
                    found = true
                    break
                }
            }
            if !found {
                fmt.panicf("Missing layer: %v.", layer)
            }
        }
    }

    when VULKAN_LAYERS {
        instance_extension_count: u32
        CHECK(vk.EnumerateInstanceExtensionProperties(nil, &instance_extension_count, nil))
        for instance_layer in instance_layers {
            count: u32
            CHECK(vk.EnumerateInstanceExtensionProperties(instance_layer, &count, nil))
            instance_extension_count += count

        }
        instance_extension_properties := make([]vk.ExtensionProperties, instance_extension_count, context.temp_allocator)
        
        cur_instance_extension_properties := instance_extension_properties
        {
            count := u32(len(cur_instance_extension_properties))
            CHECK(vk.EnumerateInstanceExtensionProperties(nil, &count, raw_data(cur_instance_extension_properties)))
            cur_instance_extension_properties = cur_instance_extension_properties[int(count):]
        }
        for instance_layer in instance_layers {
            count := u32(len(cur_instance_extension_properties))
            CHECK(vk.EnumerateInstanceExtensionProperties(instance_layer, &count, raw_data(cur_instance_extension_properties)))
            cur_instance_extension_properties = cur_instance_extension_properties[int(count):]
        }
    } else {
        instance_extension_count: u32
        CHECK(vk.EnumerateInstanceExtensionProperties(nil, &instance_extension_count, nil))
        instance_extension_properties := make([]vk.ExtensionProperties, instance_extension_count, vulkan.arena)
        CHECK(vk.EnumerateInstanceExtensionProperties(nil, &instance_extension_count, raw_data(instance_extension_properties)))
    }

    desired_instance_extensions := [?]cstring {
        "VK_KHR_get_surface_capabilities2",
    }

    vulkan.instance_extensions = make([dynamic]cstring, 0, 4 + len(desired_instance_extensions), vulkan.arena)
    append(&vulkan.instance_extensions, cstring("VK_KHR_surface"), VK_KHR_platform_surface)
    when VULKAN_DEBUG_UTILS {
        append(&vulkan.instance_extensions, "VK_EXT_debug_utils")
    }
    when VULKAN_LAYERS {
        append(&vulkan.instance_extensions, "VK_EXT_layer_settings")
    }

    missing_instance_extensions := make([dynamic]cstring, 0, len(vulkan.instance_extensions), context.temp_allocator)
    for extension in vulkan.instance_extensions {
        found := false
        for &props in instance_extension_properties {
            if extension == cstring(raw_data(props.extensionName[:])) {
                found = true
                break
            }
        }
        if !found {
            append(&missing_instance_extensions, extension)
        }
    }
    if len(missing_instance_extensions) > 0 {
        fmt.panicf("Your system is missing these instance extensions: %v.", missing_instance_extensions[:])
    }

    for extension in desired_instance_extensions {
        for &props in instance_extension_properties {
            if extension == cstring(raw_data(props.extensionName[:])) {
                append(&vulkan.instance_extensions, extension)
                break
            }
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
            enabledExtensionCount = u32(len(vulkan.instance_extensions)),
            ppEnabledExtensionNames = raw_data(vulkan.instance_extensions),
        }

        when VULKAN_DEBUG_UTILS {
            debug_info := vk.DebugUtilsMessengerCreateInfoEXT {
                sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
                messageSeverity = {.VERBOSE, .ERROR, .WARNING, .INFO},
                messageType = {.GENERAL, .PERFORMANCE},
                pfnUserCallback = vulkan_debug_callback,
                pUserData = &vulkan,
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

        CHECK(vk.CreateInstance(&create_info, nil, &vulkan.instance))
        vk.load_proc_addresses_instance(vulkan.instance)
    }

    {
        count := u32(16)
        physical_devices_array: [16]vk.PhysicalDevice
        CHECK(vk.EnumeratePhysicalDevices(vulkan.instance, &count, raw_data(physical_devices_array[:])))
        physical_devices := physical_devices_array[0:int(count)]

        #reverse for pd in physical_devices {
            properties: vk.PhysicalDeviceProperties
            vk.GetPhysicalDeviceProperties(pd, &properties)
            if (properties.deviceType == .DISCRETE_GPU) {
                vulkan.physical_device = pd
                break
            }
        }
    }

    vulkan.physical_device_properties.sType = .PHYSICAL_DEVICE_PROPERTIES_2
    vulkan.physical_device_properties.pNext = &vulkan.physical_device_vulkan_11_properties
    vulkan.physical_device_vulkan_11_properties.sType = .PHYSICAL_DEVICE_VULKAN_1_1_PROPERTIES
    vk.GetPhysicalDeviceProperties2(vulkan.physical_device, &vulkan.physical_device_properties)

    vk.GetPhysicalDeviceMemoryProperties(vulkan.physical_device, &vulkan.physical_device_memory_properties)

    vulkan.physical_device_features.sType = .PHYSICAL_DEVICE_FEATURES_2
    vulkan.physical_device_features.pNext = &vulkan.physical_device_vulkan_11_features
    vulkan.physical_device_vulkan_11_features.sType = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES
    vk.GetPhysicalDeviceFeatures2(vulkan.physical_device, &vulkan.physical_device_features)

    vulkan.physical_device_features.features.robustBufferAccess = false
    vulkan.physical_device_features.features.fullDrawIndexUint32 = false
    vulkan.physical_device_features.features.imageCubeArray = false
    vulkan.physical_device_features.features.independentBlend = false
    vulkan.physical_device_features.features.geometryShader = false
    vulkan.physical_device_features.features.tessellationShader = false
    vulkan.physical_device_features.features.sampleRateShading = false
    vulkan.physical_device_features.features.dualSrcBlend = false
    vulkan.physical_device_features.features.logicOp = false
    vulkan.physical_device_features.features.multiDrawIndirect = false
    vulkan.physical_device_features.features.drawIndirectFirstInstance = false
    vulkan.physical_device_features.features.depthClamp = false
    vulkan.physical_device_features.features.depthBiasClamp = false
    vulkan.physical_device_features.features.fillModeNonSolid = false
    vulkan.physical_device_features.features.depthBounds = false
    vulkan.physical_device_features.features.wideLines = false
    vulkan.physical_device_features.features.largePoints = false
    vulkan.physical_device_features.features.alphaToOne = false
    vulkan.physical_device_features.features.multiViewport = false
    vulkan.physical_device_features.features.samplerAnisotropy = false
    vulkan.physical_device_features.features.textureCompressionETC2 = false
    vulkan.physical_device_features.features.textureCompressionASTC_LDR = false
    vulkan.physical_device_features.features.textureCompressionBC = false
    vulkan.physical_device_features.features.occlusionQueryPrecise = false
    vulkan.physical_device_features.features.pipelineStatisticsQuery = false
    vulkan.physical_device_features.features.vertexPipelineStoresAndAtomics = false
    vulkan.physical_device_features.features.fragmentStoresAndAtomics = false
    vulkan.physical_device_features.features.shaderTessellationAndGeometryPointSize = false
    vulkan.physical_device_features.features.shaderImageGatherExtended = false
    vulkan.physical_device_features.features.shaderStorageImageExtendedFormats = false
    vulkan.physical_device_features.features.shaderStorageImageMultisample = false
    vulkan.physical_device_features.features.shaderStorageImageReadWithoutFormat = false
    vulkan.physical_device_features.features.shaderStorageImageWriteWithoutFormat = false
    vulkan.physical_device_features.features.shaderUniformBufferArrayDynamicIndexing = false
    vulkan.physical_device_features.features.shaderSampledImageArrayDynamicIndexing = false
    vulkan.physical_device_features.features.shaderStorageBufferArrayDynamicIndexing = false
    vulkan.physical_device_features.features.shaderStorageImageArrayDynamicIndexing = false
    vulkan.physical_device_features.features.shaderClipDistance = false
    vulkan.physical_device_features.features.shaderCullDistance = false
    vulkan.physical_device_features.features.shaderFloat64 = false
    vulkan.physical_device_features.features.shaderInt64 = false
    vulkan.physical_device_features.features.shaderInt16 = false
    vulkan.physical_device_features.features.shaderResourceResidency = false
    vulkan.physical_device_features.features.shaderResourceMinLod = false
    vulkan.physical_device_features.features.sparseBinding = false
    vulkan.physical_device_features.features.sparseResidencyBuffer = false
    vulkan.physical_device_features.features.sparseResidencyImage2D = false
    vulkan.physical_device_features.features.sparseResidencyImage3D = false
    vulkan.physical_device_features.features.sparseResidency2Samples = false
    vulkan.physical_device_features.features.sparseResidency4Samples = false
    vulkan.physical_device_features.features.sparseResidency8Samples = false
    vulkan.physical_device_features.features.sparseResidency16Samples = false
    vulkan.physical_device_features.features.sparseResidencyAliased = false
    vulkan.physical_device_features.features.variableMultisampleRate = false
    vulkan.physical_device_features.features.inheritedQueries = false

    vulkan.physical_device_vulkan_11_features.storageBuffer16BitAccess = false
    vulkan.physical_device_vulkan_11_features.uniformAndStorageBuffer16BitAccess = false
    vulkan.physical_device_vulkan_11_features.storagePushConstant16 = false
    vulkan.physical_device_vulkan_11_features.storageInputOutput16 = false
    vulkan.physical_device_vulkan_11_features.multiview = false
    vulkan.physical_device_vulkan_11_features.multiviewGeometryShader = false
    vulkan.physical_device_vulkan_11_features.multiviewTessellationShader = false
    vulkan.physical_device_vulkan_11_features.variablePointersStorageBuffer = false
    vulkan.physical_device_vulkan_11_features.variablePointers = false
    vulkan.physical_device_vulkan_11_features.protectedMemory = false
    vulkan.physical_device_vulkan_11_features.samplerYcbcrConversion = false
    vulkan.physical_device_vulkan_11_features.shaderDrawParameters = false

    {
        count: u32
        vk.GetPhysicalDeviceQueueFamilyProperties(vulkan.physical_device, &count, nil)
        vulkan.queue_family_properties = make([]vk.QueueFamilyProperties, count, vulkan.arena)
        vk.GetPhysicalDeviceQueueFamilyProperties(vulkan.physical_device, &count, raw_data(vulkan.queue_family_properties))
    }

    vulkan.surface = vulkan_create_surface(&vulkan) 
    CHECK(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(vulkan.physical_device, vulkan.surface, &vulkan.surface_capabilities))
    {
        count: u32
        CHECK(vk.GetPhysicalDeviceSurfaceFormatsKHR(vulkan.physical_device, vulkan.surface, &count, nil))
        vulkan.surface_formats = make([]vk.SurfaceFormatKHR, count, vulkan.arena)
        CHECK(vk.GetPhysicalDeviceSurfaceFormatsKHR(vulkan.physical_device, vulkan.surface, &count, raw_data(vulkan.surface_formats)))
    }

    // TODO: Find out if there have been any papers written about queue family properties.
    queue_priorities := [32]f32 {
        1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0,
        1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0,
        1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0,
        1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0,
    }

    queue_infos := make([dynamic]vk.DeviceQueueCreateInfo, 0, len(vulkan.queue_family_properties), context.temp_allocator)
    queue_count := 0
    for props, queue_family_idx in vulkan.queue_family_properties {
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

    when VULKAN_LAYERS {
        device_extension_count: u32
        CHECK(vk.EnumerateDeviceExtensionProperties(vulkan.physical_device, nil, &device_extension_count, nil))
        for instance_layer in instance_layers {
            count: u32
            CHECK(vk.EnumerateDeviceExtensionProperties(vulkan.physical_device, instance_layer, &count, nil))
            device_extension_count += count
        }
        device_extension_properties := make([]vk.ExtensionProperties, device_extension_count, context.temp_allocator)
        
        cur_device_extension_properties := device_extension_properties
        {
            count := u32(len(cur_device_extension_properties))
            CHECK(vk.EnumerateDeviceExtensionProperties(vulkan.physical_device, nil, &count, raw_data(cur_device_extension_properties)))
            cur_device_extension_properties = cur_device_extension_properties[int(count):]
        }
        for instance_layer in instance_layers {
            count := u32(len(cur_device_extension_properties))
            CHECK(vk.EnumerateDeviceExtensionProperties(vulkan.physical_device, instance_layer, &count, raw_data(cur_device_extension_properties)))
            cur_device_extension_properties = cur_device_extension_properties[int(count):]
        }
    } else {
        device_extension_count: u32
        CHECK(vk.EnumerateDeviceExtensionProperties(vulkan.physical_device, nil, &device_extension_count, nil))
        device_extension_properties := make([]vk.ExtensionProperties, device_extension_count, context.temp_allocator)
        CHECK(vk.EnumerateDeviceExtensionProperties(vulkan.physical_device, nil, &device_extension_count, raw_data(device_extension_properties)))
    }

    required_device_extensions := [?]cstring {
        "VK_KHR_swapchain",
    }

    missing_device_extensions := make([dynamic]cstring, 0, len(required_device_extensions), context.temp_allocator)
    for extension in required_device_extensions {
        found := false
        for &props in device_extension_properties {
            if extension == cstring(raw_data(props.extensionName[:])) {
                found = true
                break
            }
        }
        if !found {
            append(&missing_device_extensions, extension)
        }
    }
    if len(missing_device_extensions) > 0 {
        fmt.panicf("Your system is missing these device extensions: %v.", missing_device_extensions[:])
    }

    desired_device_extensions := [?]cstring {
        "VK_EXT_full_screen_exclusive",
    }

    vulkan.device_extensions = make([dynamic]cstring, 0, len(required_device_extensions) + len(desired_device_extensions), vulkan.arena)
    append(&vulkan.device_extensions, ..required_device_extensions[:])

    for extension in desired_device_extensions {
        for &props in device_extension_properties {
            if extension == cstring(raw_data(props.extensionName[:])) {
                append(&vulkan.device_extensions, extension)
                break
            }
        }
    }

    CHECK(vk.CreateDevice(vulkan.physical_device, &{
        sType = .DEVICE_CREATE_INFO,
        pNext = &vulkan.physical_device_features,
        queueCreateInfoCount = u32(len(queue_infos)),
        pQueueCreateInfos = raw_data(queue_infos),
        enabledExtensionCount = u32(len(vulkan.device_extensions)),
        ppEnabledExtensionNames = raw_data(vulkan.device_extensions[:]),
    }, nil, &vulkan.device))
    vk.load_proc_addresses_device(vulkan.device)

    vulkan.queues = make([]vk.Queue, queue_count, vulkan.arena)
    queue_array_idx := 0
    for props, queue_family_idx in vulkan.queue_family_properties {
        for queue_idx in 0..<int(props.queueCount) {
            vk.GetDeviceQueue(vulkan.device, u32(queue_family_idx), u32(queue_idx), &vulkan.queues[queue_array_idx])
            queue_array_idx += 1
        }
    }

    // TODO
    vulkan.graphics_queue = vulkan.queues[0]
    vulkan.present_queue = vulkan.queues[0]

    vulkan.swapchain_format = vulkan.surface_formats[0] // TODO
    vulkan.swapchain_extent = vulkan.surface_capabilities.currentExtent

    {
        info := vk.SwapchainCreateInfoKHR {
            sType = .SWAPCHAIN_CREATE_INFO_KHR,
            surface = vulkan.surface,
            minImageCount = vulkan.surface_capabilities.minImageCount, // TODO
            imageFormat = vulkan.swapchain_format.format,
            imageColorSpace = vulkan.swapchain_format.colorSpace,
            imageExtent = vulkan.swapchain_extent,
            imageArrayLayers = 1,
            imageUsage = {.COLOR_ATTACHMENT},
            preTransform = vulkan.surface_capabilities.currentTransform,
            compositeAlpha = {.OPAQUE},
            presentMode = .FIFO, // TODO
            clipped = true,
        }

        full_screen_info := vk.SurfaceFullScreenExclusiveInfoEXT {
            sType = .SURFACE_FULL_SCREEN_EXCLUSIVE_INFO_EXT,
            fullScreenExclusive = .DEFAULT,
        }

        when ODIN_OS == .Windows {
            win32_full_screen_info := vk.SurfaceFullScreenExclusiveWin32InfoEXT {
                sType = .SURFACE_FULL_SCREEN_EXCLUSIVE_WIN32_INFO_EXT,
                hmonitor = win32_get_monitor(),
            }
        }

        if slice.contains(vulkan.device_extensions[:], "VK_EXT_full_screen_exclusive") {
            info.pNext = &full_screen_info
            when ODIN_OS == .Windows {
                full_screen_info.pNext = &win32_full_screen_info
            }
        }

        CHECK(vk.CreateSwapchainKHR(vulkan.device, &info, nil, &vulkan.swapchain))
    }

    {
        count: u32
        CHECK(vk.GetSwapchainImagesKHR(vulkan.device, vulkan.swapchain, &count, nil))
        vulkan.swapchain_images = make([]vk.Image, count, vulkan.arena)
        CHECK(vk.GetSwapchainImagesKHR(vulkan.device, vulkan.swapchain, &count, raw_data(vulkan.swapchain_images)))
    }

    vulkan.swapchain_image_views = make([]vk.ImageView, len(vulkan.swapchain_images), vulkan.arena)
    for &swapchain_image_view, idx in vulkan.swapchain_image_views {
        CHECK(vk.CreateImageView(vulkan.device, &{
            sType = .IMAGE_VIEW_CREATE_INFO,
            image = vulkan.swapchain_images[idx],
            viewType = .D2,
            format = vulkan.swapchain_format.format,
            subresourceRange = {
                aspectMask = {.COLOR}, 
                levelCount = 1, 
                layerCount = 1
            },
        }, nil, &swapchain_image_view))
    }
    vulkan.frames = make([]Vulkan_Frame, len(vulkan.swapchain_images), vulkan.arena)

    {
        color_attachment := vk.AttachmentDescription {
            format = vulkan.swapchain_format.format,
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

        CHECK(vk.CreateRenderPass(vulkan.device, &info, nil, &vulkan.render_pass))
    }

    CHECK(vk.CreateCommandPool(vulkan.device, &{
        sType = .COMMAND_POOL_CREATE_INFO,
        flags = {.TRANSIENT, .RESET_COMMAND_BUFFER},

        // TODO:
        // queueFamilyIndex = 0,
    }, nil, &vulkan.command_pool))

    command_buffers := make([]vk.CommandBuffer, len(vulkan.frames), context.temp_allocator)
    CHECK(vk.AllocateCommandBuffers(
        vulkan.device, 
        &{ sType = .COMMAND_BUFFER_ALLOCATE_INFO, commandPool = vulkan.command_pool, commandBufferCount = u32(len(vulkan.frames))}, 
        raw_data(command_buffers)))
    for &frame, idx in vulkan.frames {
        frame.command_buffer = command_buffers[idx]
    }

    for &frame in vulkan.frames {
        CHECK(vk.CreateFence(vulkan.device, &{sType = .FENCE_CREATE_INFO, flags = {.SIGNALED} }, nil, &frame.fence_in_flight))
    }

    for &frame in vulkan.frames {
        CHECK(vk.CreateSemaphore(vulkan.device, &{sType = .SEMAPHORE_CREATE_INFO}, nil, &frame.sem_image_available))
        CHECK(vk.CreateSemaphore(vulkan.device, &{sType = .SEMAPHORE_CREATE_INFO}, nil, &frame.sem_render_finished))
    }

    vulkan.swapchain_framebuffers = make([]vk.Framebuffer, len(vulkan.swapchain_images), vulkan.arena)
    for idx in 0..<len(vulkan.swapchain_images) {
        attachments := [?]vk.ImageView {
            vulkan.swapchain_image_views[idx],
        }

        info := vk.FramebufferCreateInfo {
            sType = .FRAMEBUFFER_CREATE_INFO,
            renderPass = vulkan.render_pass,
            attachmentCount = u32(len(attachments)),
            pAttachments = raw_data(attachments[:]),
            width = vulkan.swapchain_extent.width,
            height = vulkan.swapchain_extent.height,
            layers = 1,
        }
        CHECK(vk.CreateFramebuffer(vulkan.device, &info, nil, &vulkan.swapchain_framebuffers[idx]))
    }

    cgltf_data: ^cgltf.data
    if d, r := cgltf_load("assets/chocolate_donut.glb"); r != .success {
        panic("Failed to load assets/chocolate_donut.glb.")
    } else {
        cgltf_data = d
    }

    assert(cgltf_data.file_type == .glb)
    assert(cgltf_data.file_data == nil)
    assert(cgltf_data.asset.version == "2.0")
    assert(cgltf_data.asset.extras == {})
    assert(cgltf_data.asset.extensions_count == 0)

    for mesh in cgltf_data.meshes {
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

    for material in cgltf_data.materials {
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

    for accessor in cgltf_data.accessors {
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

    assert(len(cgltf_data.buffers) == 1)
    // buffer{
    //  name = "",
    //  size = 1756,
    //  uri = "",
    //  data = 0x0,
    //  data_free_method = "none",
    //  extras = extras_t{
    //      start_offset = 0,
    //      end_offset = 0,
    //      data = <nil>,
    //  },
    //  extensions_count = 0,
    //  extensions = <nil>,
    // }

    assert(len(cgltf_data.images) == 0)
    assert(len(cgltf_data.textures) == 0)
    assert(len(cgltf_data.samplers) == 0)
    assert(len(cgltf_data.skins) == 0)
    assert(len(cgltf_data.cameras) == 0)
    assert(len(cgltf_data.lights) == 0)

    for node in cgltf_data.nodes {
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

    assert(len(cgltf_data.scenes) == 1)
    // scene{
    //  name = "Scene",
    //  nodes = [
    //      &node{
    //          name = "Donut",
    //          parent = <nil>,
    //          children = [],
    //          skin = <nil>,
    //          mesh = 0x21C6DEF7EAE,
    //          camera = <nil>,
    //          light = <nil>,
    //          weights = [],
    //          has_translation = true,
    //          has_rotation = true,
    //          has_scale = true,
    //          has_matrix = false,
    //          translation = [
    //              0,
    //              0.025177613,
    //              0,
    //          ],
    //          rotation = [
    //              0,
    //              -0.7889224,
    //              0,
    //              0.61449289,
    //          ],
    //          scale = [
    //              1,
    //              1.0000026,
    //              1,
    //          ],
    //          matrix_ = [
    //              1,
    //              0,
    //              0,
    //              0,
    //              0,
    //              1,
    //              0,
    //              0,
    //              0,
    //              0,
    //              1,
    //              0,
    //              0,
    //              0,
    //              0,
    //              1,
    //          ],
    //          extras = extras_t{
    //              start_offset = 0,
    //              end_offset = 0,
    //              data = <nil>,
    //          },
    //          has_mesh_gpu_instancing = false,
    //          mesh_gpu_instancing = mesh_gpu_instancing{
    //              attributes = [],
    //          },
    //          extensions_count = 0,
    //          extensions = <nil>,
    //      },
    //      &node{
    //          name = "Table",
    //          parent = <nil>,
    //          children = [],
    //          skin = <nil>,
    //          mesh = 0x21C6DEF7F0E,
    //          camera = <nil>,
    //          light = <nil>,
    //          weights = [],
    //          has_translation = true,
    //          has_rotation = false,
    //          has_scale = true,
    //          has_matrix = false,
    //          translation = [
    //              -1.2678384,
    //              -0.001,
    //              -3.2460144,
    //          ],
    //          rotation = [
    //              0,
    //              0,
    //              0,
    //              1,
    //          ],
    //          scale = [
    //              0.33391109,
    //              0.33391109,
    //              0.33391109,
    //          ],
    //          matrix_ = [
    //              1,
    //              0,
    //              0,
    //              0,
    //              0,
    //              1,
    //              0,
    //              0,
    //              0,
    //              0,
    //              1,
    //              0,
    //              0,
    //              0,
    //              0,
    //              1,
    //          ],
    //          extras = extras_t{
    //              start_offset = 0,
    //              end_offset = 0,
    //              data = <nil>,
    //          },
    //          has_mesh_gpu_instancing = false,
    //          mesh_gpu_instancing = mesh_gpu_instancing{
    //              attributes = [],
    //          },
    //          extensions_count = 0,
    //          extensions = <nil>,
    //      },
    //      &node{
    //          name = "Abstract Plate",
    //          parent = <nil>,
    //          children = [],
    //          skin = <nil>,
    //          mesh = 0x21C6DEF7F6E,
    //          camera = <nil>,
    //          light = <nil>,
    //          weights = [],
    //          has_translation = true,
    //          has_rotation = false,
    //          has_scale = false,
    //          has_matrix = false,
    //          translation = [
    //              0,
    //              0.0051408298,
    //              0,
    //          ],
    //          rotation = [
    //              0,
    //              0,
    //              0,
    //              1,
    //          ],
    //          scale = [
    //              1,
    //              1,
    //              1,
    //          ],
    //          matrix_ = [
    //              1,
    //              0,
    //              0,
    //              0,
    //              0,
    //              1,
    //              0,
    //              0,
    //              0,
    //              0,
    //              1,
    //              0,
    //              0,
    //              0,
    //              0,
    //              1,
    //          ],
    //          extras = extras_t{
    //              start_offset = 0,
    //              end_offset = 0,
    //              data = <nil>,
    //          },
    //          has_mesh_gpu_instancing = false,
    //          mesh_gpu_instancing = mesh_gpu_instancing{
    //              attributes = [],
    //          },
    //          extensions_count = 0,
    //          extensions = <nil>,
    //      },
    //      &node{
    //          name = "Vast",
    //          parent = <nil>,
    //          children = [
    //              0x21C6DEF641A,
    //          ],
    //          skin = <nil>,
    //          mesh = 0x21C6DEF802E,
    //          camera = <nil>,
    //          light = <nil>,
    //          weights = [],
    //          has_translation = true,
    //          has_rotation = false,
    //          has_scale = false,
    //          has_matrix = false,
    //          translation = [
    //              0.27141318,
    //              0,
    //              -0.22245401,
    //          ],
    //          rotation = [
    //              0,
    //              0,
    //              0,
    //              1,
    //          ],
    //          scale = [
    //              1,
    //              1,
    //              1,
    //          ],
    //          matrix_ = [
    //              1,
    //              0,
    //              0,
    //              0,
    //              0,
    //              1,
    //              0,
    //              0,
    //              0,
    //              0,
    //              1,
    //              0,
    //              0,
    //              0,
    //              0,
    //              1,
    //          ],
    //          extras = extras_t{
    //              start_offset = 0,
    //              end_offset = 0,
    //              data = <nil>,
    //          },
    //          has_mesh_gpu_instancing = false,
    //          mesh_gpu_instancing = mesh_gpu_instancing{
    //              attributes = [],
    //          },
    //          extensions_count = 0,
    //          extensions = <nil>,
    //      },
    //  ],
    //  extras = extras_t{
    //      start_offset = 0,
    //      end_offset = 0,
    //      data = <nil>,
    //  },
    //  extensions_count = 0,
    //  extensions = <nil>,
    // }

    assert(cgltf_data.animations == nil)
    assert(cgltf_data.variants == nil)
    // cgltf_data.extensions_used = ["KHR_materials_specular", "KHR_materials_ior"]
    assert(cgltf_data.extensions_required == nil)

    vertex_buffer_size, index_buffer_size, uniform_buffer_size: vk.DeviceSize

    for buffer_view in cgltf_data.buffer_views {
        // buffer_view.name
        assert(buffer_view.buffer != nil)
        assert(buffer_view.stride == 0)
        switch buffer_view.type {
            case .invalid:
            case .vertices:
                vertex_buffer_size += vk.DeviceSize(buffer_view.size)
            case .indices:
                index_buffer_size += vk.DeviceSize(buffer_view.size)
        }
        assert(buffer_view.data == nil)
        assert(!buffer_view.has_meshopt_compression)
        assert(buffer_view.meshopt_compression == {})
        assert(buffer_view.extras == {})
        assert(buffer_view.extensions_count == 0)
    }

    for node in cgltf_data.nodes {
        if node.name == "Donut" {
            assert(node.has_translation == true)
            uniform_buffer_size += size_of(Vector3)
            assert(node.has_rotation == true)
            uniform_buffer_size += size_of(Vector4)
            assert(node.has_scale == true)
            uniform_buffer_size += size_of(Vector3)
        }
    }

    assert(vertex_buffer_size + index_buffer_size == vk.DeviceSize(len(cgltf_data.bin)))

    vulkan_allocator := vulkan_create_allocator()

    vertex_buffer := vulkan_create_buffer(
        &vulkan, &vulkan_allocator, 
        vertex_buffer_size, 
        {.TRANSFER_DST, .VERTEX_BUFFER}, 
        {.DEVICE_LOCAL}, {.HOST_VISIBLE})

    index_buffer := vulkan_create_buffer(
        &vulkan, &vulkan_allocator, 
        index_buffer_size, 
        {.TRANSFER_DST, .INDEX_BUFFER}, 
        {.DEVICE_LOCAL}, {.HOST_VISIBLE})

    uniform_buffer := vulkan_create_buffer(
        &vulkan, &vulkan_allocator, 
        uniform_buffer_size, 
        {.TRANSFER_DST, .UNIFORM_BUFFER}, 
        {.DEVICE_LOCAL}, {.HOST_VISIBLE})

    vertex_buffer_staging_buffer := vulkan_create_buffer(
        &vulkan, &vulkan_allocator, 
        vertex_buffer_size, 
        {.TRANSFER_SRC}, 
        {.HOST_VISIBLE, .HOST_COHERENT}, {.DEVICE_LOCAL})

    index_buffer_staging_buffer := vulkan_create_buffer(
        &vulkan, &vulkan_allocator, 
        index_buffer_size, 
        {.TRANSFER_SRC}, 
        {.HOST_VISIBLE, .HOST_COHERENT}, {.DEVICE_LOCAL})

    uniform_buffer_staging_buffer := vulkan_create_buffer(
        &vulkan, &vulkan_allocator, 
        uniform_buffer_size, 
        {.TRANSFER_SRC}, 
        {.HOST_VISIBLE, .HOST_COHERENT}, {.DEVICE_LOCAL})

    vulkan_alloc(&vulkan, &vulkan_allocator)

    {
        data := vulkan_map_memory(&vulkan, &vulkan_allocator, vertex_buffer_staging_buffer, 0, vertex_buffer_size)
        defer vulkan_unmap_memory(&vulkan, &vulkan_allocator, vertex_buffer_staging_buffer)

        offset := vk.DeviceSize(0)
        for buffer_view in cgltf_data.buffer_views {
            if buffer_view.type == .vertices {
                copy(data, cgltf_data.bin[int(offset):int(offset)+int(buffer_view.size)])
                offset += vk.DeviceSize(buffer_view.size)
            }
        }
    }

    {
        data := vulkan_map_memory(&vulkan, &vulkan_allocator, index_buffer_staging_buffer, 0, index_buffer_size)
        defer vulkan_unmap_memory(&vulkan, &vulkan_allocator, index_buffer_staging_buffer)

        offset := vk.DeviceSize(0)
        for buffer_view in cgltf_data.buffer_views {
            if buffer_view.type == .indices {
                copy(data, cgltf_data.bin[int(offset):int(offset)+int(buffer_view.size)])
                offset += vk.DeviceSize(buffer_view.size)
            }
        }
    }

    Uniforms :: struct {
        translation: Vector3,
        rotation: Vector4,
        scale: Vector3,
    }
    #assert(size_of(Uniforms) == 40)

    Vertex :: struct {
        pos: Vector3,
        normal: Vector3,
        texcoord: Vector2,
    }
    #assert(size_of(Vertex) == 32)

    {
        data := vulkan_map_memory(&vulkan, &vulkan_allocator, uniform_buffer_staging_buffer, 0, uniform_buffer_size)
        defer vulkan_unmap_memory(&vulkan, &vulkan_allocator, uniform_buffer_staging_buffer)

        for &node in cgltf_data.nodes {
            if node.name == "Donut" {
                intrinsics.mem_copy(&data[0], &node.translation, size_of(Vector3))
                intrinsics.mem_copy(&data[size_of(Vector3)], &node.rotation, size_of(Vector4))
                intrinsics.mem_copy(&data[size_of(Vector3) + size_of(Vector4)], &node.scale, size_of(Vector3))

                break
            }
        }
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
    CHECK(vk.CreateDescriptorSetLayout(
        vulkan.device,
        &descriptor_set_layout_info,
        nil,
        &descriptor_set_layout))

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
    CHECK(vk.CreateDescriptorPool(
        vulkan.device,
        &descriptor_pool_info,
        nil,
        &descriptor_pool))

    descriptor_set_allocate_info := vk.DescriptorSetAllocateInfo {
        sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
        descriptorPool = descriptor_pool,
        descriptorSetCount = 1,
        pSetLayouts = &descriptor_set_layout,
    }

    descriptor_set: vk.DescriptorSet
    CHECK(vk.AllocateDescriptorSets(
        vulkan.device,
        &descriptor_set_allocate_info,
        &descriptor_set))

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

    pipeline_layout_info := vk.PipelineLayoutCreateInfo {
        sType = .PIPELINE_LAYOUT_CREATE_INFO,
        setLayoutCount = 1,
        pSetLayouts = &descriptor_set_layout,
    }
    pipeline_layout: vk.PipelineLayout
    CHECK(vk.CreatePipelineLayout(vulkan.device, &pipeline_layout_info, nil, &pipeline_layout))

    CHECK(vk.CreatePipelineCache(vulkan.device, &{sType = .PIPELINE_CACHE_CREATE_INFO}, nil, &vulkan.pipeline_cache))

    vert := vulkan_create_shader_stage(vulkan.device, "build/debug/donut_vert.spv", .VERTEX)
    frag := vulkan_create_shader_stage(vulkan.device, "build/debug/donut_frag.spv", .FRAGMENT)

    stages := [?]vk.PipelineShaderStageCreateInfo {vert, frag}

    vertex_input_bindings := [?]vk.VertexInputBindingDescription {
        {
            binding = 0,
            stride = size_of(Vertex),
            inputRate = .VERTEX,
        },
    }

    vertex_input_attributes := [?]vk.VertexInputAttributeDescription {
        {
            location = 0,
            binding = 0,
            format = .R32G32B32_SFLOAT,
            offset = u32(offset_of(Vertex, pos)),
        },
        {
            location = 1,
            binding = 0,
            format = .R32G32B32_SFLOAT,
            offset = u32(offset_of(Vertex, normal)),
        },
        {
            location = 2,
            binding = 0,
            format = .R32G32_SFLOAT,
            offset = u32(offset_of(Vertex, texcoord)),
        },
    }

    vertex_input_state := vk.PipelineVertexInputStateCreateInfo {
        sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        vertexBindingDescriptionCount = u32(len(vertex_input_bindings)),
        pVertexBindingDescriptions = raw_data(vertex_input_bindings[:]),
        vertexAttributeDescriptionCount = u32(len(vertex_input_attributes)),
        pVertexAttributeDescriptions = raw_data(vertex_input_attributes[:]),
    }

    input_assembly_state := vk.PipelineInputAssemblyStateCreateInfo {
        sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        topology = .TRIANGLE_LIST,
    }

    viewport := vk.Viewport {
        width = f32(vulkan.swapchain_extent.width),
        height = f32(vulkan.swapchain_extent.height),
        maxDepth = 1.0,
    }
    scissor := vk.Rect2D {
        extent = vulkan.swapchain_extent,
    }
    viewport_state := vk.PipelineViewportStateCreateInfo {
        sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        viewportCount = 1,
        pViewports = &viewport,
        scissorCount = 1,
        pScissors = &scissor,
    }

    rasterization_state := vk.PipelineRasterizationStateCreateInfo {
        sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        polygonMode = .FILL,
        cullMode = {},
        frontFace = .COUNTER_CLOCKWISE,
        lineWidth = 1.0,
    }

    multisample_state := vk.PipelineMultisampleStateCreateInfo {
        sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        rasterizationSamples = {._1},
    }

    color_blend_attachment_state := vk.PipelineColorBlendAttachmentState {
        colorWriteMask = {.R, .G, .B, .A},
    }
    color_blend_state := vk.PipelineColorBlendStateCreateInfo {
        sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        attachmentCount = 1,
        pAttachments = &color_blend_attachment_state,
    }

    dynamic_state := vk.PipelineDynamicStateCreateInfo {
        sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    }

    pipeline_info := vk.GraphicsPipelineCreateInfo {
        sType = .GRAPHICS_PIPELINE_CREATE_INFO,
        flags = {},
        stageCount = u32(len(stages)),
        pStages = raw_data(stages[:]),
        pVertexInputState = &vertex_input_state,
        pInputAssemblyState = &input_assembly_state,
        pViewportState = &viewport_state,
        pRasterizationState = &rasterization_state,
        pMultisampleState = &multisample_state,
        pColorBlendState = &color_blend_state,
        pDynamicState = &dynamic_state,
        layout = pipeline_layout,
        renderPass = vulkan.render_pass,
    }
    when VULKAN_DISABLE_PIPELINE_OPTIMIZATION {
        pipeline_info.flags += {.DISABLE_OPTIMIZATION}
    }

    pipeline: vk.Pipeline
    CHECK(vk.CreateGraphicsPipelines(
        device = vulkan.device,
        pipelineCache = vulkan.pipeline_cache,
        createInfoCount = 1,
        pCreateInfos = &pipeline_info,
        pAllocator = nil,
        pPipelines = &pipeline))

    for app_update() {
        CHECK(vk.WaitForFences(vulkan.device, 1, &vulkan.frames[vulkan.frame_idx].fence_in_flight, true, max(u64)))
        CHECK(vk.ResetFences(vulkan.device, 1, &vulkan.frames[vulkan.frame_idx].fence_in_flight))

        CHECK(vk.AcquireNextImageKHR(vulkan.device, vulkan.swapchain, max(u64), vulkan.frames[vulkan.frame_idx].sem_image_available, vk.Fence{}, &vulkan.image_idx))

        if vulkan.image_idx == 0 {
            @static app_ready := -1
            if app_ready == -1 {
                app_ready += 1
            } else if app_ready == 0 {
                app_ready += 1
                app_show()
            }
        }

        cb := vulkan.frames[vulkan.frame_idx].command_buffer
        CHECK(vk.BeginCommandBuffer(cb, &{
            sType = .COMMAND_BUFFER_BEGIN_INFO,
            flags = {.ONE_TIME_SUBMIT},
        }))

        @static staged := false

        if !staged {
            staged = true

            buffer_barriers_before := [?]vk.BufferMemoryBarrier {
                {
                    sType = .BUFFER_MEMORY_BARRIER,
                    srcAccessMask = {},
                    dstAccessMask = {.TRANSFER_WRITE},
                    buffer = vertex_buffer,
                    offset = 0,
                    size = vertex_buffer_size,
                },
                {
                    sType = .BUFFER_MEMORY_BARRIER,
                    srcAccessMask = {},
                    dstAccessMask = {.TRANSFER_WRITE},
                    buffer = index_buffer,
                    offset = 0,
                    size = index_buffer_size,
                },
                {
                    sType = .BUFFER_MEMORY_BARRIER,
                    srcAccessMask = {},
                    dstAccessMask = {.TRANSFER_WRITE},
                    buffer = uniform_buffer,
                    offset = 0,
                    size = uniform_buffer_size,
                },

                {
                    sType = .BUFFER_MEMORY_BARRIER,
                    srcAccessMask = {},
                    dstAccessMask = {.TRANSFER_READ},
                    buffer = vertex_buffer_staging_buffer,
                    offset = 0,
                    size = vertex_buffer_size,
                },
                {
                    sType = .BUFFER_MEMORY_BARRIER,
                    srcAccessMask = {},
                    dstAccessMask = {.TRANSFER_READ},
                    buffer = index_buffer_staging_buffer,
                    offset = 0,
                    size = index_buffer_size,
                },
                {
                    sType = .BUFFER_MEMORY_BARRIER,
                    srcAccessMask = {},
                    dstAccessMask = {.TRANSFER_READ},
                    buffer = uniform_buffer_staging_buffer,
                    offset = 0,
                    size = uniform_buffer_size,
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
                srcBuffer = vertex_buffer_staging_buffer,
                dstBuffer = vertex_buffer,
                regionCount = 1,
                pRegions = &vk.BufferCopy{size = vertex_buffer_size})

            vk.CmdCopyBuffer(
                commandBuffer = cb,
                srcBuffer = index_buffer_staging_buffer,
                dstBuffer = index_buffer,
                regionCount = 1,
                pRegions = &vk.BufferCopy{size = index_buffer_size})

            vk.CmdCopyBuffer(
                commandBuffer = cb,
                srcBuffer = uniform_buffer_staging_buffer,
                dstBuffer = uniform_buffer,
                regionCount = 1,
                pRegions = &vk.BufferCopy{size = uniform_buffer_size})

            buffer_barriers_after := [?] vk.BufferMemoryBarrier {
                {
                    sType = .BUFFER_MEMORY_BARRIER,
                    srcAccessMask = {.TRANSFER_WRITE},
                    dstAccessMask = {.VERTEX_ATTRIBUTE_READ},
                    buffer = vertex_buffer,
                    offset = 0,
                    size = vertex_buffer_size,
                },
                {
                    sType = .BUFFER_MEMORY_BARRIER,
                    srcAccessMask = {.TRANSFER_WRITE},
                    dstAccessMask = {.INDEX_READ},
                    buffer = index_buffer,
                    offset = 0,
                    size = index_buffer_size,
                },
            }

            vk.CmdPipelineBarrier(
                commandBuffer = cb,
                srcStageMask = {.TRANSFER}, dstStageMask = {.VERTEX_INPUT},
                dependencyFlags = {},
                memoryBarrierCount = 0, pMemoryBarriers = nil,
                bufferMemoryBarrierCount = u32(len(buffer_barriers_after)), pBufferMemoryBarriers = raw_data(buffer_barriers_after[:]),
                imageMemoryBarrierCount = 0, pImageMemoryBarriers = nil)

            buffer_barriers_after2 := [?] vk.BufferMemoryBarrier {
                {
                    sType = .BUFFER_MEMORY_BARRIER,
                    srcAccessMask = {.TRANSFER_WRITE},
                    dstAccessMask = {.UNIFORM_READ},
                    buffer = uniform_buffer,
                    offset = 0,
                    size = uniform_buffer_size,
                },
            }

            vk.CmdPipelineBarrier(
                commandBuffer = cb,
                srcStageMask = {.TRANSFER}, dstStageMask = {.VERTEX_SHADER},
                dependencyFlags = {},
                memoryBarrierCount = 0, pMemoryBarriers = nil,
                bufferMemoryBarrierCount = u32(len(buffer_barriers_after2)), pBufferMemoryBarriers = raw_data(buffer_barriers_after2[:]),
                imageMemoryBarrierCount = 0, pImageMemoryBarriers = nil)
        }

        vk.CmdBeginRenderPass(vulkan.frames[vulkan.frame_idx].command_buffer, &{
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
        {
            vk.CmdBindPipeline(cb, .GRAPHICS, pipeline)
            offset: vk.DeviceSize = 0
            vk.CmdBindVertexBuffers(
                commandBuffer = cb,
                firstBinding = 0, bindingCount = 1,
                pBuffers = &vertex_buffer, pOffsets = &offset)
            vk.CmdBindIndexBuffer(
                commandBuffer = cb,
                buffer = index_buffer,
                offset = 0,
                indexType = .UINT16)
            vk.CmdBindDescriptorSets(
                commandBuffer = cb,
                pipelineBindPoint = .GRAPHICS,
                layout = pipeline_layout,
                firstSet = 0,
                descriptorSetCount = 1,
                pDescriptorSets = &descriptor_set,
                dynamicOffsetCount = 0,
                pDynamicOffsets = nil)
            vk.CmdDrawIndexed(
                commandBuffer = cb,
                indexCount = u32(index_buffer_size/size_of(u16)), 
                instanceCount = 1,
                firstIndex = 0, 
                vertexOffset = 0, 
                firstInstance = 0)
        }
        vk.CmdEndRenderPass(vulkan.frames[vulkan.frame_idx].command_buffer)

        CHECK(vk.EndCommandBuffer(cb))

        wait_stage := vk.PipelineStageFlags{.COLOR_ATTACHMENT_OUTPUT}
        submit_info := vk.SubmitInfo {
            sType = .SUBMIT_INFO,
            waitSemaphoreCount = 1,
            pWaitSemaphores = &vulkan.frames[vulkan.frame_idx].sem_image_available,
            pWaitDstStageMask = &wait_stage,
            commandBufferCount = 1,
            pCommandBuffers = &cb,
            signalSemaphoreCount = 1,
            pSignalSemaphores = &vulkan.frames[vulkan.frame_idx].sem_render_finished,
        }
        CHECK(vk.QueueSubmit(vulkan.graphics_queue, 1, &submit_info, vulkan.frames[vulkan.frame_idx].fence_in_flight))

        present_info := vk.PresentInfoKHR {
            sType = .PRESENT_INFO_KHR,
            waitSemaphoreCount = 1,
            pWaitSemaphores = &vulkan.frames[vulkan.frame_idx].sem_render_finished,
            swapchainCount = 1,
            pSwapchains = &vulkan.swapchain,
            pImageIndices = &vulkan.image_idx,
        }
        CHECK(vk.QueuePresentKHR(vulkan.graphics_queue, &present_info))

        vulkan.frame_idx = (vulkan.frame_idx + 1) % len(vulkan.frames)

        free_all(context.temp_allocator)
    }
}

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