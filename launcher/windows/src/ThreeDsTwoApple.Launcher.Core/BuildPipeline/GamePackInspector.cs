using ThreeDsTwoApple.Launcher.Core.Models;

namespace ThreeDsTwoApple.Launcher.Core.BuildPipeline;

/// <summary>Validates that a GamePack.dylib is real Mach-O AOT code, never a placeholder.</summary>
public static class GamePackInspector
{
    /// <summary>Mach-O magic check so a placeholder pack can never pass as AOT code.</summary>
    public static void VerifyMachO(string path)
    {
        using var stream = File.OpenRead(path);
        Span<byte> magic = stackalloc byte[4];
        if (stream.Read(magic) != 4)
        {
            throw new LauncherToolException("pack_invalid", $"{path} is too small to be a Mach-O dylib.", "Rebuild the GamePack with the Windows local build.");
        }
        var value = (uint)(magic[0] | (magic[1] << 8) | (magic[2] << 16) | (magic[3] << 24));
        // 0xFEEDFACF (64-bit), 0xFEEDFACE (32-bit), 0xCAFEBABE (fat), and their byte swaps.
        var isMachO = value is 0xFEEDFACF or 0xFEEDFACE or 0xCAFEBABE or 0xCFFAEDFE or 0xCEFAEDFE or 0xBEBAFECA;
        if (!isMachO)
        {
            throw new LauncherToolException("pack_placeholder",
                $"{path} is not a Mach-O dylib (magic 0x{value:X8}); it is a placeholder, not installable AOT code.",
                "Build the GamePack with the Windows local build (3dsrecomp + LLVM/LLD), not with a preview placeholder.");
        }
    }
}
