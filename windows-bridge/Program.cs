using System.Runtime.InteropServices.WindowsRuntime;
using M5WisprBridge;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Storage.Streams;

const string DeviceName = "m5sticks3";
var serviceUuid = Guid.Parse("b3d7f070-3f2d-4c2e-94b8-1f0a95b7a100");
var streamUuid = Guid.Parse("b3d7f071-3f2d-4c2e-94b8-1f0a95b7a100");
var configUuid = Guid.Parse("b3d7f072-3f2d-4c2e-94b8-1f0a95b7a100");

try
{
    if (args is ["--self-test"])
    {
        ProtocolSelfTest.Run();
        return;
    }

    using var devices = new MMDeviceEnumerator();
    if (args is ["--list-devices"])
    {
        foreach (var device in devices.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active))
            Console.WriteLine($"{device.FriendlyName}\n  {device.ID}");
        return;
    }

    if (args is ["--help"] or [] || args.Length != 2 || args[0] != "--device")
    {
        Usage(args.Length == 0 ? Console.Out : Console.Error);
        Environment.ExitCode = args.Length == 0 ? 0 : 1;
        return;
    }

    using var endpoint = FindEndpoint(devices, args[1]);
    Console.WriteLine($"Audio output: {endpoint.FriendlyName}");
    Console.WriteLine("Wispr Flow should use the matching virtual cable recording endpoint.");

    while (true)
    {
        try { await RunConnection(endpoint); }
        catch (Exception error) { Console.Error.WriteLine($"Connection ended: {error.Message}"); }
        Console.WriteLine("Reconnecting...");
        await Task.Delay(1_000);
    }
}
catch (Exception error)
{
    Console.Error.WriteLine($"error: {error.Message}");
    Environment.ExitCode = 1;
}

async Task RunConnection(MMDevice endpoint)
{
    using var ble = await ScanAndConnect();
    Console.WriteLine($"Connected to {ble.Name}; discovering PCM service...");

    var services = await ble.GetGattServicesForUuidAsync(serviceUuid, BluetoothCacheMode.Uncached);
    if (services.Status != GattCommunicationStatus.Success || services.Services.Count == 0)
        throw new IOException($"PCM service discovery failed: {services.Status}");
    using var service = services.Services[0];

    var configResult = await service.GetCharacteristicsForUuidAsync(configUuid, BluetoothCacheMode.Uncached);
    if (configResult.Status != GattCommunicationStatus.Success || configResult.Characteristics.Count == 0)
        throw new IOException($"Config characteristic discovery failed: {configResult.Status}");
    var configRead = await configResult.Characteristics[0].ReadValueAsync(BluetoothCacheMode.Uncached);
    if (configRead.Status != GattCommunicationStatus.Success)
        throw new IOException($"Config read failed: {configRead.Status}");
    var config = StreamConfig.Parse(ToBytes(configRead.Value));
    Console.WriteLine($"PCM format: {config.SampleRate} Hz, {config.BitsPerSample}-bit, {config.Channels} channel(s)");

    var streamResult = await service.GetCharacteristicsForUuidAsync(streamUuid, BluetoothCacheMode.Uncached);
    if (streamResult.Status != GattCommunicationStatus.Success || streamResult.Characteristics.Count == 0)
        throw new IOException($"Stream characteristic discovery failed: {streamResult.Status}");
    var stream = streamResult.Characteristics[0];
    using var audio = new AudioSink(endpoint, config);
    uint? expectedSequence = null;

    stream.ValueChanged += (_, eventArgs) =>
    {
        try
        {
            var packet = StreamPacket.Parse(ToBytes(eventArgs.CharacteristicValue));
            if (packet.IsStart)
            {
                audio.Reset();
                Console.WriteLine($"PCM stream started at sequence {packet.Sequence}");
            }
            else if (expectedSequence is uint expected && packet.Sequence != expected)
                Console.WriteLine($"warning: sequence gap; expected {expected}, got {packet.Sequence}");

            expectedSequence = unchecked(packet.Sequence + 1);
            audio.Write(packet);
            if (packet.IsStop)
            {
                Console.WriteLine($"PCM stream stopped at sequence {packet.Sequence}");
                expectedSequence = null;
            }
        }
        catch (Exception error) { Console.Error.WriteLine($"warning: dropped packet: {error.Message}"); }
    };

    var subscribed = await stream.WriteClientCharacteristicConfigurationDescriptorAsync(
        GattClientCharacteristicConfigurationDescriptorValue.Notify);
    if (subscribed != GattCommunicationStatus.Success)
        throw new IOException($"Stream subscription failed: {subscribed}");

    Console.WriteLine("Subscribed. Hold Button A to talk. Press Ctrl+C to quit.");
    var disconnected = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    ble.ConnectionStatusChanged += (_, _) =>
    {
        if (ble.ConnectionStatus == BluetoothConnectionStatus.Disconnected)
            disconnected.TrySetResult();
    };
    await disconnected.Task;
}

async Task<BluetoothLEDevice> ScanAndConnect()
{
    Console.WriteLine($"Scanning for {DeviceName}...");
    var watcher = new BluetoothLEAdvertisementWatcher { ScanningMode = BluetoothLEScanningMode.Active };
    var found = new TaskCompletionSource<ulong>(TaskCreationOptions.RunContinuationsAsynchronously);
    watcher.Received += (_, advertisement) =>
    {
        if (advertisement.Advertisement.LocalName == DeviceName ||
            advertisement.Advertisement.ServiceUuids.Contains(serviceUuid))
            found.TrySetResult(advertisement.BluetoothAddress);
    };
    watcher.Start();
    var address = await found.Task;
    watcher.Stop();
    return await BluetoothLEDevice.FromBluetoothAddressAsync(address)
        ?? throw new IOException("Windows could not open the discovered BLE device");
}

static byte[] ToBytes(IBuffer buffer)
{
    using var reader = DataReader.FromBuffer(buffer);
    var bytes = new byte[buffer.Length];
    reader.ReadBytes(bytes);
    return bytes;
}

static MMDevice FindEndpoint(MMDeviceEnumerator devices, string query)
{
    var matches = devices.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active)
        .Where(device => device.ID.Equals(query, StringComparison.OrdinalIgnoreCase) ||
                         device.FriendlyName.Contains(query, StringComparison.OrdinalIgnoreCase))
        .ToList();
    return matches.Count switch
    {
        1 => matches[0],
        0 => throw new ArgumentException($"No active playback endpoint matches '{query}'. Run --list-devices."),
        _ => throw new ArgumentException($"Multiple playback endpoints match '{query}'. Pass an exact endpoint ID.")
    };
}

static void Usage(TextWriter output) => output.WriteLine("""
M5 Wispr Windows bridge

  M5WisprBridge --list-devices
  M5WisprBridge --device "CABLE Input"
  M5WisprBridge --self-test
""");

sealed class AudioSink : IDisposable
{
    private readonly BufferedWaveProvider buffer;
    private readonly WasapiOut output;

    public AudioSink(MMDevice endpoint, StreamConfig config)
    {
        buffer = new BufferedWaveProvider(new WaveFormat((int)config.SampleRate, config.BitsPerSample, config.Channels))
        {
            BufferDuration = TimeSpan.FromSeconds(2),
            DiscardOnBufferOverflow = true,
            ReadFully = true
        };

        ISampleProvider samples = buffer.ToSampleProvider();
        if (samples.WaveFormat.Channels == 1 && endpoint.AudioClient.MixFormat.Channels == 2)
            samples = new MonoToStereoSampleProvider(samples);
        else if (samples.WaveFormat.Channels != endpoint.AudioClient.MixFormat.Channels)
            throw new NotSupportedException(
                $"Cannot map {samples.WaveFormat.Channels} input channels to {endpoint.AudioClient.MixFormat.Channels} output channels");
        if (samples.WaveFormat.SampleRate != endpoint.AudioClient.MixFormat.SampleRate)
            samples = new WdlResamplingSampleProvider(samples, endpoint.AudioClient.MixFormat.SampleRate);

        output = new WasapiOut(endpoint, AudioClientShareMode.Shared, true, 20);
        output.Init(samples);
        output.Play();
    }

    public void Reset() => buffer.ClearBuffer();

    public void Write(StreamPacket packet)
    {
        if (packet.Channels != buffer.WaveFormat.Channels)
            throw new InvalidDataException($"Packet has {packet.Channels} channels; expected {buffer.WaveFormat.Channels}");
        if (!packet.Pcm.IsEmpty)
        {
            var pcm = packet.Pcm.ToArray();
            buffer.AddSamples(pcm, 0, pcm.Length);
        }
    }

    public void Dispose() => output.Dispose();
}
