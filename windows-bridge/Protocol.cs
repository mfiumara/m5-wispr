using System.Buffers.Binary;

namespace M5WisprBridge;

internal readonly record struct StreamConfig(
    uint SampleRate,
    byte BitsPerSample,
    byte Channels,
    ushort SamplesPerPacket,
    uint HeaderBytes)
{
    public static StreamConfig Parse(ReadOnlySpan<byte> data)
    {
        if (data.Length < 16)
            throw new InvalidDataException($"Config is too short: {data.Length} bytes");
        if (!data[..4].SequenceEqual("M5W1"u8))
            throw new InvalidDataException("Config magic is not M5W1");

        var config = new StreamConfig(
            BinaryPrimitives.ReadUInt32LittleEndian(data[4..8]),
            data[8],
            data[9],
            BinaryPrimitives.ReadUInt16LittleEndian(data[10..12]),
            BinaryPrimitives.ReadUInt32LittleEndian(data[12..16]));

        if (config.SampleRate == 0 || config.BitsPerSample != 16 || config.Channels == 0)
            throw new InvalidDataException(
                $"Unsupported format: {config.SampleRate} Hz, {config.BitsPerSample}-bit, {config.Channels} channel(s)");
        return config;
    }
}

internal readonly record struct StreamPacket(
    uint Sequence,
    byte Flags,
    byte Channels,
    ushort SampleCount,
    ReadOnlyMemory<byte> Pcm)
{
    public bool IsStart => (Flags & 1) != 0;
    public bool IsStop => (Flags & 2) != 0;

    public static StreamPacket Parse(ReadOnlyMemory<byte> data)
    {
        var span = data.Span;
        if (span.Length < 8)
            throw new InvalidDataException($"Packet is too short: {span.Length} bytes");

        var samples = BinaryPrimitives.ReadUInt16LittleEndian(span[6..8]);
        var expected = 8 + samples * 2;
        if (span[5] == 0)
            throw new InvalidDataException("Packet has no channels");
        if (span.Length != expected)
            throw new InvalidDataException($"Packet length is {span.Length}; expected {expected}");

        return new StreamPacket(
            BinaryPrimitives.ReadUInt32LittleEndian(span[..4]),
            span[4], span[5], samples, data[8..]);
    }
}

internal static class ProtocolSelfTest
{
    public static void Run()
    {
        byte[] configBytes = [
            (byte)'M', (byte)'5', (byte)'W', (byte)'1',
            0x80, 0x3e, 0, 0, 16, 1, 120, 0, 8, 0, 0, 0
        ];
        var config = StreamConfig.Parse(configBytes);
        Require(config == new StreamConfig(16_000, 16, 1, 120, 8), "config");

        byte[] packetBytes = [42, 0, 0, 0, 1, 1, 2, 0, 0x34, 0x12, 0xcc, 0xff];
        var packet = StreamPacket.Parse(packetBytes);
        Require(packet.Sequence == 42 && packet.IsStart && !packet.IsStop, "flags and sequence");
        Require(packet.Pcm.Span.SequenceEqual(packetBytes.AsSpan(8)), "PCM payload");

        try
        {
            StreamPacket.Parse(packetBytes.AsMemory(0, 11));
            throw new Exception("truncated packet was accepted");
        }
        catch (InvalidDataException) { }

        Console.WriteLine("self-test passed: config and PCM packet parsers");
    }

    private static void Require(bool condition, string name)
    {
        if (!condition) throw new Exception($"self-test failed: {name}");
    }
}
