/* Console program for runtime/check-runtime.sh: on a stereo output device, a Spatial Audio stream with 5.1
 * static objects must play as two channels, with center and sides mixed in. Wine opened it with all six, and
 * the macOS driver kept only the two the device has, so dialogue (center) went silent (GTA V Enhanced).
 *
 * The stream's own audio client isn't reachable, but its session is: a session's channel count is the widest
 * stream in it, so a second client in the same session reads it back. Prints "spatial: ok", "spatial: skip
 * (<why>)" when there is no stereo device to test with, or "spatial: <what went wrong>". */
#define COBJMACROS
#include <initguid.h>
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <spatialaudioclient.h>
#include <stdio.h>

static int fail(const char *what, HRESULT hr)
{
    printf("spatial: %s failed (0x%08lx)\n", what, (unsigned long)hr);
    return 1;
}

int main(void)
{
    IMMDeviceEnumerator *devices;
    IMMDevice *device;
    IAudioClient *probe;
    ISpatialAudioClient *spatial;
    IAudioFormatEnumerator *formats;
    ISpatialAudioObjectRenderStream *stream;
    IChannelAudioVolume *session;
    SpatialAudioObjectRenderStreamActivationParams params = {0};
    WAVEFORMATEX *mix, *object_format;
    PROPVARIANT blob;
    UINT32 channels = 0;
    HRESULT hr;

    CoInitializeEx(NULL, COINIT_MULTITHREADED);
    hr = CoCreateInstance(&CLSID_MMDeviceEnumerator, NULL, CLSCTX_INPROC_SERVER, &IID_IMMDeviceEnumerator,
                          (void **)&devices);
    if (FAILED(hr)) return fail("CoCreateInstance(MMDeviceEnumerator)", hr);
    if (FAILED(IMMDeviceEnumerator_GetDefaultAudioEndpoint(devices, eRender, eConsole, &device)))
    {
        puts("spatial: skip (no output device)");
        return 0;
    }
    hr = IMMDevice_Activate(device, &IID_IAudioClient, CLSCTX_INPROC_SERVER, NULL, (void **)&probe);
    if (FAILED(hr)) return fail("Activate(IAudioClient)", hr);
    hr = IAudioClient_GetMixFormat(probe, &mix);
    if (FAILED(hr)) return fail("GetMixFormat", hr);
    if (mix->nChannels != 2)
    {
        printf("spatial: skip (the output device has %u channels, not 2)\n", mix->nChannels);
        return 0;
    }

    hr = IMMDevice_Activate(device, &IID_ISpatialAudioClient, CLSCTX_INPROC_SERVER, NULL, (void **)&spatial);
    if (FAILED(hr)) return fail("Activate(ISpatialAudioClient)", hr);
    hr = ISpatialAudioClient_GetSupportedAudioObjectFormatEnumerator(spatial, &formats);
    if (FAILED(hr)) return fail("GetSupportedAudioObjectFormatEnumerator", hr);
    hr = IAudioFormatEnumerator_GetFormat(formats, 0, &object_format);
    if (FAILED(hr)) return fail("GetFormat", hr);

    params.ObjectFormat = object_format;
    params.StaticObjectTypeMask = AudioObjectType_FrontLeft | AudioObjectType_FrontRight |
        AudioObjectType_FrontCenter | AudioObjectType_LowFrequency | AudioObjectType_SideLeft |
        AudioObjectType_SideRight;
    params.Category = AudioCategory_GameEffects;
    params.EventHandle = CreateEventA(NULL, FALSE, FALSE, NULL);
    blob.vt = VT_BLOB;
    blob.blob.cbSize = sizeof(params);
    blob.blob.pBlobData = (BYTE *)&params;
    hr = ISpatialAudioClient_ActivateSpatialAudioStream(spatial, &blob, &IID_ISpatialAudioObjectRenderStream,
                                                        (void **)&stream);
    if (FAILED(hr)) return fail("ActivateSpatialAudioStream", hr);

    hr = IAudioClient_Initialize(probe, AUDCLNT_SHAREMODE_SHARED, 0, 1000000, 0, mix, NULL);
    if (FAILED(hr)) return fail("Initialize(probe)", hr);
    hr = IAudioClient_GetService(probe, &IID_IChannelAudioVolume, (void **)&session);
    if (FAILED(hr)) return fail("GetService(IChannelAudioVolume)", hr);
    IChannelAudioVolume_GetChannelCount(session, &channels);
    if (channels != 2)
    {
        printf("spatial: a 5.1 stream on a stereo device plays as %u channels; center and sides are lost\n",
               channels);
        return 1;
    }
    puts("spatial: ok");
    return 0;
}
