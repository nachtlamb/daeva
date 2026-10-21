/* enumerate DXGI adapters, create a D3D12 device and report FL / binding tier / shader model */
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <stdio.h>
#include <dxgi1_6.h>
#include <d3d12.h>

typedef HRESULT (WINAPI *create_factory2_fn)(UINT, REFIID, void **);
typedef HRESULT (WINAPI *create_device_fn)(IUnknown *, D3D_FEATURE_LEVEL, REFIID, void **);

static const char *sm_name(D3D_SHADER_MODEL sm)
{
    static char buf[16];
    snprintf(buf, sizeof(buf), "%d.%d", sm >> 4, sm & 0xf);
    return buf;
}

int main(void)
{
    HMODULE dxgi = LoadLibraryA("dxgi.dll"), d3d12 = LoadLibraryA("d3d12.dll");
    create_factory2_fn create_factory2;
    create_device_fn create_device;
    IDXGIFactory4 *factory;
    IDXGIAdapter1 *adapter;
    ID3D12Device *device;
    char path[MAX_PATH];
    UINT i;
    HRESULT hr;
    int ok = 0;

    if (!dxgi || !d3d12) { printf("FAIL load dxgi=%p d3d12=%p\n", dxgi, d3d12); return 1; }
    GetModuleFileNameA(d3d12, path, sizeof(path));
    printf("d3d12.dll: %s\n", path);
    GetModuleFileNameA(dxgi, path, sizeof(path));
    printf("dxgi.dll:  %s\n", path);

    create_factory2 = (create_factory2_fn)GetProcAddress(dxgi, "CreateDXGIFactory2");
    create_device = (create_device_fn)GetProcAddress(d3d12, "D3D12CreateDevice");
    if (!create_factory2 || !create_device) { printf("FAIL missing exports\n"); return 1; }

    if (FAILED(hr = create_factory2(0, &IID_IDXGIFactory4, (void **)&factory)))
    {
        printf("FAIL CreateDXGIFactory2 %#lx\n", hr);
        return 1;
    }

    for (i = 0; IDXGIFactory4_EnumAdapters1(factory, i, &adapter) == S_OK; i++)
    {
        DXGI_ADAPTER_DESC1 desc;
        D3D12_FEATURE_DATA_FEATURE_LEVELS levels;
        D3D_FEATURE_LEVEL want[] = {D3D_FEATURE_LEVEL_12_2, D3D_FEATURE_LEVEL_12_1, D3D_FEATURE_LEVEL_12_0,
                                    D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0};
        D3D12_FEATURE_DATA_D3D12_OPTIONS opts = {0};
        D3D12_FEATURE_DATA_SHADER_MODEL sm = {D3D_SHADER_MODEL_6_6};

        IDXGIAdapter1_GetDesc1(adapter, &desc);
        printf("adapter %u: %ls vendor=%04x device=%04x vram=%llu MiB flags=%#x\n", i, desc.Description,
               desc.VendorId, desc.DeviceId, (unsigned long long)desc.DedicatedVideoMemory >> 20, desc.Flags);
        if (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) { IDXGIAdapter1_Release(adapter); continue; }

        hr = create_device((IUnknown *)adapter, D3D_FEATURE_LEVEL_12_0, &IID_ID3D12Device, (void **)&device);
        if (FAILED(hr)) { printf("  D3D12CreateDevice(FL 12_0) FAIL %#lx\n", hr); IDXGIAdapter1_Release(adapter); continue; }

        levels.NumFeatureLevels = ARRAYSIZE(want);
        levels.pFeatureLevelsRequested = want;
        hr = ID3D12Device_CheckFeatureSupport(device, D3D12_FEATURE_FEATURE_LEVELS, &levels, sizeof(levels));
        printf("  max feature level: %#x (hr %#lx)\n", SUCCEEDED(hr) ? levels.MaxSupportedFeatureLevel : 0, hr);
        hr = ID3D12Device_CheckFeatureSupport(device, D3D12_FEATURE_D3D12_OPTIONS, &opts, sizeof(opts));
        printf("  resource binding tier: %d (hr %#lx)\n", opts.ResourceBindingTier, hr);
        hr = ID3D12Device_CheckFeatureSupport(device, D3D12_FEATURE_SHADER_MODEL, &sm, sizeof(sm));
        printf("  highest shader model: %s (hr %#lx)\n", SUCCEEDED(hr) ? sm_name(sm.HighestShaderModel) : "?", hr);

        if (SUCCEEDED(hr) && levels.MaxSupportedFeatureLevel >= D3D_FEATURE_LEVEL_12_0) ok = 1;
        ID3D12Device_Release(device);
        IDXGIAdapter1_Release(adapter);
    }
    IDXGIFactory4_Release(factory);
    printf("%s\n", ok ? "D3D12 OK" : "D3D12 FAIL");
    return ok ? 0 : 1;
}
